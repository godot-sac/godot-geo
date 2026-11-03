# GeoTerrain

`GeoTerrain` (`addons/geo/geo_terrain.gd`) loads a terrain package ([format](package-format.md)), draws it, answers
height queries and keeps a collision patch under a target. Pure GDScript; Godot 4.3+ engine APIs only.

```
GeoTerrain                 loading, queries, collision, alignment with DisGeoOrigin
├── Backend (internal)     GeoTerrainBackend: draws the grid (first backend: GeoCdlodBackend)
└── Collision (internal)   StaticBody3D + HeightMapShape3D around the target
```

## Properties
| Property | Default | |
|---|---|---|
| `package_path` | `""` | package directory (contains `terrain.json`); setting it loads the package |
| `backend` | `CDLOD` | renderer; only CDLOD so far |
| `lod_distance` | 4.0 | level 0 range in patch sizes (64 cells); higher = sharper and slower, minimum 3.5 |
| `cast_shadows` | true | |
| `water` | true | draw the package's water layer (if any) as water; the water surface is the terrain itself, see [Water](#water) |
| `ground_detail` | 0 | strength of the ground detail near the camera (0–1): with a land cover layer, per-class detail textures; without one, procedural noise. Not data: it only breaks up the blur of 10 m imagery seen from a few metres. The demos use 0.6 |
| `auto_layers` | true | add the [layers](#layers) the package has data for (buildings, roads, trees) unless a child of that type exists |
| `collision_enabled` | true | |
| `collision_size` | 2000 | edge of the square collision patch, metres; it follows the target |
| `collision_target` | — | node the patch follows; the active camera if empty |
| `collision_layer` | 1 | |
| `verify_package` | false | check SHA-256 of the package files on load |

## Methods
| Method | |
|---|---|
| `load_package() -> Error` | (re)loads `package_path`; `ERR_FILE_NOT_FOUND` / `ERR_INVALID_DATA` on failure, with an engine error |
| `height_at(x, z) -> float` | global surface height; `NAN` outside the package |
| `geodetic_height(lat, lon) -> float` | WGS84 ellipsoidal height of the ground; `NAN` outside |
| `geodetic_to_global(lat, lon, h) -> Vector3` / `global_to_geodetic(p)` | positions in the terrain's frame |
| `raycast(from, direction, max_distance, mask) -> Dictionary` | first hit: `hit`, `position`, `distance`, `normal`, `obstacle` (`building_id` for buildings) |
| `line_of_sight(a, b, refraction, mask) -> Dictionary` | see [Visibility queries](#visibility-queries) |
| `viewshed(observer, radius, target_height, resolution, refraction, mask) -> Image` | visible / hidden ground around an eye position |
| `viewshed_rect(observer, radius) -> Rect2` | global x / z square covered by `viewshed` |
| `set_overlay(image, rect)` / `clear_overlay()` | RGBA image blended over the terrain colour in a global x / z rectangle |
| `to_package_local(p)` / `from_package_local(p)` | global position <-> package frame (for `GeoVisibility` on a thread) |
| `water_at(x, z) -> float` | share of the ground that is water there (0..1, from the water layer), 0 without one, `NAN` outside |
| `surface_height_local(x, z) -> float` | surface height in the package frame (for layers and threads) |
| `layers() -> Array[GeoTerrainLayer]` | the layer children |
| `attribution() -> PackedStringArray` | data notices to show with the terrain |
| `is_loaded()`, signal `loaded` | |

`origin_offset` and `origin_warning` report the alignment below. Keep the node unrotated and unscaled.

## One surface everywhere
The drawn surface at full detail, `height_at`, `geodetic_height` and the collision shape are the same surface: the
height grid with each cell split into two triangles along its NE–SW diagonal (from column + 1, row to column,
row + 1). That diagonal is the one Jolt (Godot 4.7's default 3D physics) uses for `HeightMapShape3D`, so a ray cast
hits `height_at` (tested within 1 cm). Between triangulation and the package's bilinear
convention the difference is a few metres at most at cell centres in rough terrain; at grid points both are exact.
Farther away the renderer draws coarser levels, so the picture may differ from `height_at` there; that is invisible
at those distances.

## Visibility queries
`GeoVisibility` (`addons/geo/geo_visibility.gd`) runs the queries on the package grid; the `GeoTerrain` methods wrap
it in scene coordinates. They use the surface above, so a query agrees with what is drawn and with collision.

**Line of sight** `line_of_sight(a, b, refraction := 0.0)`, `a` and `b` are eye / target positions (lift points on
the ground by the eye or antenna height):

| Key | |
|---|---|
| `visible` | no part of the segment inside the package is below the surface (1 mm tolerance) |
| `point` | first obstruction, where the segment enters the terrain; `b` if visible |
| `distance` | from `a` to `point` |
| `clearance` | the segment's lowest height above the surface, metres; negative when blocked (depth) |
| `clearance_point` | where that is |
| `partial` | part of the segment is outside the package and was not tested |
| `obstacle` | what blocked: `"terrain"`, `"building"`, `"tree"`; `""` when visible |
| `building_id` | the blocking building's index in the package, when `obstacle` is `"building"` |

An end point that is NaN or infinite (typically `height_at` of a point outside the package) gives at once
`visible: false`, `partial: true`, `distance` and `clearance` NaN and an `error` text; `raycast` with such an origin
or a zero direction returns `hit: false` with `error`, and `viewshed` with a NaN eye or radius returns `null`. No
engine error is pushed, since a moving unit may meet this every frame.

`mask` (`GeoVisibility.TERRAIN | BUILDINGS | TREES`, default `ALL`) picks what blocks; layers the package does not
have are ignored. Buildings are blocks: the footprint (with holes) from its base, or its `min_height` for parts
above the ground, to the top of the walls plus half the roof (roof shapes are not modelled in queries); the test
is exact on the footprint polygons (a 25 m grid per 500 m tile finds the candidates). Tree crowns are solid from
the ground to the canopy height of their 10 m sample wherever the tree layer puts trees, sampled every 5 m along
the segment. `clearance` is measured against the terrain only. In the viewshed, buildings and crowns raise the
surface of the pixels whose centre they cover (the target then sits on the roof).
Cost in the 10 km Üsküdar package (GDScript, RTX 4080 machine): 3 km at street level 1 ms, 5 km from a tower 11 ms
(most of it the crown samples), 1.9 km over the Bosphorus 2 ms.

The walk is exact for the triangulated surface: between consecutive crossings of grid lines and cell diagonals
(`x`, `z` or `x + z` on a grid line) both the segment and the surface are planar, so the clearance is linear there
and is checked at every crossing. Cost: about three evaluations per cell crossed (0.4 ms for 3 km at 10 m in
GDScript). Earth curvature is always included, because package heights are relative to the origin's tangent plane.
`refraction` is the coefficient *k* of a ray bending towards the ground with radius *R / k*: the segment is raised by
*s₁ s₂ k / 2R* (*s₁*, *s₂* distances to the ends). Common values: 0 (geometric), 0.13 (optical), 0.25 (radio,
the "4/3 Earth").

**Ray cast** `raycast(from, direction, max_distance)`: the same walk, stopping at the first entry; `normal` is the
hit triangle's. Used by the visibility demo to pick points under the mouse without physics.

**Viewshed** `viewshed(observer, radius, target_height, resolution := 256, refraction := 0.0)` returns an `Image`
(`FORMAT_LA8`, `resolution²`, row 0 = north) over `viewshed_rect(observer, radius)`: luminance 255 where a point
`target_height` above the ground is visible from `observer`, 0 where hidden; alpha 0 outside the radius or the
package. Algorithm: R2 ray sweep (W. R. Franklin, C. Ray, *Higher isn't necessarily better: visibility algorithms
and experiments*, 1994): one ray from the observer to every border pixel, stepping at most one pixel and one height
sample, keeping the steepest slope so far; each pixel takes the verdict of the step nearest its centre. It agrees
with per-pixel `line_of_sight` on 96–98 % of pixels in the tests (differences at visibility edges). Cost: about
`2 · resolution² · max(1, pixel / spacing)` surface samples; Ankara at 10 m, radius 5 km, 256²: 0.3–1.4 s in
GDScript, so the demo runs it on a `WorkerThreadPool` task with `GeoVisibility.viewshed(terrain.package,
terrain.to_package_local(eye), ...)` (node transforms may only be read on the main thread).
`GeoVisibility.viewshed_colors(image)` turns the result into an RGBA overlay for `set_overlay`.

GRASS GIS `r.viewshed` (Haverkort, Toma, Zhuang) was used as background reading only; no code was taken from it
(GPL). Copernicus DEM is a surface model: buildings and trees block the view as they would at their roof height.

Demo: `demo/visibility.tscn` ([screenshot](visibility/viewshed.jpg)); `-- --check` prints a JSON report (viewshed
time and visible share, lines of sight on three rings, their agreement with the viewshed, a ray cast) and exits 1
if something is implausible.

## Water
A package built with `--layers water` has `water.png`, an anti-aliased coverage mask from OpenStreetMap water
polygons (see [package format](package-format.md)). There is no separate water plane: Copernicus DEM sets the sea to
0 m above EGM2008 and lakes to one level, and the package turns that into the local frame with the geoid and the
Earth's curvature (about 70 m of drop at 30 km), so the terrain surface over water is already the water surface.
`height_at`, `line_of_sight` and collision see the water surface; ships and other surface units clamped to the
ground float on it. The renderer only changes the shading where the mask says water: the shoreline is cut at 50 %
coverage with a one-pixel ramp (sharp at any distance), a sum of six travelling waves gives the normals near the
camera (each wave fades out before it gets shorter than a few pixels, so the far sea does not show stripes),
roughness rises with distance, a shallow tint follows the shore, and far away the water takes the imagery's tone.
No bathymetry: the sea floor is not modelled.

## Accuracy
What the numbers mean for a simulation, from the data up:

| Source of error | Size | Notes |
|---|---|---|
| Copernicus DEM GLO-30 (the data) | absolute vertical < 4 m (LE90), horizontal < 6 m (CE90), 30 m posts | product specification; it is a surface model (roofs, crowns), see [Layers](#layers) for the approximate ground under buildings |
| Resampling to the package grid | 0.23 mm at grid points against GDAL bilinear sampling | tested (`tests/python`) |
| Triangulated surface vs bilinear | a few metres at most at cell centres in rough terrain, 0 at grid points | the drawn surface, `height_at`, collision and queries all use the triangles |
| Geoid (EGM2008 grid, 2.5') | about 7 cm against the NGA test point | applied once when the package is built |
| WGS84 / ENU / ECEF conversions | below 1 mm | `GeoMath` in double precision; tested against pymap3d and PROJ |
| Scene positions | float32 in standard Godot builds: about 2 mm at 30 km from the origin | fine for one package; larger worlds need a double-precision build |
| Sentinel-2 imagery | 10 m pixels, georeferenced to about 10 m | colour only |
| Layers (water, buildings, roads, trees) | OpenStreetMap / Overture positions; heights mostly estimated | see [city view: how close to reality](city.md#how-close-to-reality) |

## Layers
Children of `GeoTerrain` derived from `GeoTerrainLayer` draw what the package's optional layers describe (see
[package format](package-format.md) and `tools/layers.py`, `tools/buildings.py`, `tools/roads.py`). With
`auto_layers` they are added when the package has the data; add one yourself to change its settings. They work in
the package frame and stream around the camera; heavy work runs on `WorkerThreadPool` tasks.

| Layer | Data | Drawing |
|---|---|---|
| ground detail (CDLOD shader) | `landcover.png` (ESA WorldCover) | per class a detail texture and normal (own procedural set, 8 slices, `tools/make_detail_textures.py`) modulates the imagery out to 1.5 km; in built-up areas with 3D buildings the imagery (mostly roofs) is pulled towards street tones out to 4 km |
| `GeoBuildingLayer` | `buildings.bin` | per 500 m tile: up to `max_distance` (4 km) every building, walls with windows from the shader, flat / hipped / gabled / pyramidal roofs, domes; beyond, to `far_distance` (12 km), buildings ≥ `far_min_height` (20 m) as flat blocks |
| `GeoRoadLayer` | `roads.bin` | roads painted by Godot's 2D renderer into two textures around the camera (2 km at 1 m / px, 8 km at 4 m / px; asphalt, pavement, rail) and blended by the terrain shader; bridge decks as meshes; tunnels not drawn |
| `GeoTreeLayer` | `landcover.png`, `canopy.png`, `footprints.png` | deterministic placement per 10 m sample (tree class: `density` trees; elsewhere one where the canopy is ≥ 3 m), none on water or buildings; 3D low-poly trees to 600 m, impostor cards to 3 km |

Under the headless display server (`--headless`: tests, servers, CI) the layers create no meshes, MultiMeshes or
ring viewports (the dummy renderer rejects them); they still load their data, count what they would draw and serve
the visibility queries, so scenes need not switch them off. Slender structures (at least 60 m tall and over three
times as tall as wide, such as the Çamlıca TV tower) are drawn as bare light concrete without windows.

The building layer and the visibility queries share one decoder (`GeoTerrainPackage.buildings_data()`,
`GeoBuildingData`, thread-safe).

**Ground under buildings.** Copernicus DEM is a surface model; a package with buildings stores an approximate
bare earth instead (`height.surface = "dtm-approx"`): under building footprints the DEM is filled in from the
surrounding samples (never from water), under trees it is lowered by half the canopy height, and the lowering is
capped at 8 m (or half the canopy) so built-over hilltops stay. Buildings stand on the lowest ground under their
footprint and reach 2 m below it.

**Heights.** OpenStreetMap `height`, else `building:levels` × 3 m, else the GHSL GHS-BUILT-H average net building
height of the 100 m cell varied per building, else 3–6 floors. In the 10 km Üsküdar package 0.3 % come from a
height tag, 3.8 % from levels and 95.8 % from GHSL (Microsoft's ML footprints have no heights for Türkiye); in the
60 km package 3.5 % tag, 4.1 % levels, 91.3 % GHSL, 1.0 % default. Check against the 1 596 tagged buildings of the
60 km package: GHSL median 15.0 m, tags 15.7 m; DSM minus ground under the footprint gave 9.8 m and is not used.
GHSL is a 100 m cell average, so single buildings can be several floors off. What this means in practice:
[city.md](city.md#how-close-to-reality).

**Measurements** (10 km Üsküdar package, 1920 × 1080, RTX 4080, Windows, `demo/city.tscn -- --bench`): a fixed
route at 150 m and 500 m above the ground with all layers streaming: median frame 2.0 ms, p95 2.9–3.3 ms, p99
7.1–7.6 ms; 5–6 frames per run over 33 ms (40–70 ms, one per 2 km of flight, when the far road ring moves; the first
frame after a jump 50 ms); 0.8–0.9 k draw calls, 5.9–8.4 M primitives, 552 MB video memory. Around the reference
views 30–62 k buildings, 100–150 k trees and 3.6–8.8 k road pieces are drawn.

## Alignment with godot-dis
If the scene has a node in group `dis_geo_origin` (godot-dis `DisGeoOrigin`) — godot-geo does not depend on
godot-dis, it reads `latitude`, `longitude`, `height` by name:
- same latitude / longitude (within 1e-7°, ~1 cm), different height: both frames share the tangent plane, so the
  terrain is shifted by `package height − scene height` (`origin_offset`); `height_at` includes it;
- different latitude / longitude: a warning (`origin_warning`); the terrain is not moved, because a different
  tangent plane is a rotation, not a shift. Rebuild the package at the scene origin.

## GeoMath
`GeoMath` (`addons/geo/geo_math.gd`) is a standalone class of static WGS84 functions in double precision (GDScript
floats are 64-bit); it needs no terrain and can be used on its own:

| Function | |
|---|---|
| `geodetic_to_ecef(lat, lon, h)` / `ecef_to_geodetic(ecef)` | geodetic (degrees, ellipsoidal metres) <-> ECEF |
| `ecef_to_enu(ecef, lat0, lon0, h0)` / `enu_to_ecef(enu, ...)` | ECEF <-> east / north / up at an origin |
| `geodetic_to_local(lat, lon, h, lat0, lon0, h0) -> Vector3` / `local_to_geodetic(p, ...)` | <-> Godot axes (+X east, +Y up, −Z north), the frame of godot-dis `DisGeoOrigin` |
| `geodetic_to_utm(lat, lon) -> Dictionary` / `utm_to_geodetic(zone, north, e, n)` | UTM (Krüger series to 6th order, Karney 2011; Norway and Svalbard zone exceptions) |
| `geodetic_to_mgrs(lat, lon, digits := 5) -> String` / `mgrs_to_geodetic(mgrs)` | MGRS, truncated as the standard requires; back to the centre of the square |

UTM and MGRS cover −80° ≤ latitude < 84° (UPS polar areas are not supported). Tests: `tests/golden/geo_cases.txt`
(shared with godot-dis, from pymap3d) and `tests/golden/utm_mgrs_cases.txt` (UTM from PROJ, checked again by
`tests/python/test_utm_golden.py`; MGRS strings from the Python `mgrs` package, MIT, used only to generate the file
with `tools/make_utm_golden.py`). The visibility demo shows observer and cursor positions as MGRS.

## With 3D Tiles for Godot (not tested yet)
Streamed 3D Tiles (buildings, photogrammetry, Cesium ion or other tile servers) are out of scope; 3D Tiles for Godot
(Battle Road Labs, Apache-2.0) covers them. Using both in one scene should only need a shared origin: set its
`CesiumGeoreference` origin to the package origin from `terrain.json` (`origin.latitude`, `origin.longitude`,
`origin.height`; heights here are WGS84 ellipsoidal). Its documentation does not state the local axis convention,
so check it against ours (+X east, +Y up, −Z north) with a landmark known in both, e.g. by comparing
`GeoTerrain.geodetic_to_global(lat, lon, h)` with where the tileset draws that point. Our package heights are a
surface model like most photogrammetry, so streamed buildings and the terrain should meet at street level only
where both sources agree. This combination has not been tried; reports are welcome.

## CDLOD backend
`GeoCdlodBackend` implements Continuous Distance-Dependent Level of Detail (F. Strugar, 2009):
- An implicit quadtree covers the grid; a leaf is 64 × 64 height cells, the root `64 · 2^L` cells (L = 6 for a
  4000-cell package; nodes past the grid edge are skipped, partial ones are clamped).
- Each frame the nodes are chosen by distance: level *l* within `lod_distance · 64 · spacing · 2^l` of the camera.
  Every chosen node is a `MeshInstance3D` with the same 65 × 65 grid mesh and an instance uniform (origin, step,
  level), with an exact AABB from a min/max pyramid computed at load, so Godot culls each node for the camera and for
  every shadow cascade.
- The vertex shader reads heights from the R32F texture with `texelFetch` (float textures are not filterable
  everywhere) and geomorphs odd vertices onto the next coarser grid over the last 30 % of each range, so levels meet
  without cracks or popping. A test checks that the chosen nodes tile the grid exactly once and neighbours differ by
  at most one level.
- Normals are computed per pixel from the height mip whose texels are about one pixel wide, so distant slopes do not
  shimmer.

Ankara 40 × 40 km at 10 m, 1600 × 900, RTX 4080: load 0.8 s, 0.6–0.8 ms per frame, 0.3–1.9 M triangles, 37–262
nodes ([stats](phase2/stats.json), [views](phase2/views_sheet.jpg)).

## Limits (v0.1)
- Queries are GDScript: fine for tens of lines of sight per frame and occasional viewsheds, not for thousands of
  sensors per frame.
- Packages are read from the file system (`res://` in the editor, absolute paths); exported games need the package
  next to the executable. One package at a time, no streaming.
- Close to the ground the picture is limited by the data (30 m DEM, 10 m imagery); the land cover detail textures
  and the 3D layers hide it at the scale of a street, not of a doorway.
- Building heights are mostly estimates (see [Layers](#layers)); roof shapes are guessed for untagged buildings.
  Buildings and trees have no collision shapes; only the visibility queries see them.
  Bridge decks follow the ground at the bridge ends: the Bosphorus bridges sit 10–20 m lower than reality and have
  no towers or cables.
