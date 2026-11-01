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
| `ground_detail` | 0 | procedural detail on the ground near the camera (0–1); not data, it only breaks up the blur of 10 m imagery seen from a few metres. The demos use 0.6 |
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
| `raycast(from, direction, max_distance) -> Dictionary` | first hit on the surface: `hit`, `position`, `distance`, `normal` |
| `line_of_sight(a, b, refraction) -> Dictionary` | see [Visibility queries](#visibility-queries) |
| `viewshed(observer, radius, target_height, resolution, refraction) -> Image` | visible / hidden ground around an eye position |
| `viewshed_rect(observer, radius) -> Rect2` | global x / z square covered by `viewshed` |
| `set_overlay(image, rect)` / `clear_overlay()` | RGBA image blended over the terrain colour in a global x / z rectangle |
| `to_package_local(p)` / `from_package_local(p)` | global position <-> package frame (for `GeoVisibility` on a thread) |
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

## Alignment with godot-dis
If the scene has a node in group `dis_geo_origin` (godot-dis `DisGeoOrigin`) — godot-geo does not depend on
godot-dis, it reads `latitude`, `longitude`, `height` by name:
- same latitude / longitude (within 1e-7°, ~1 cm), different height: both frames share the tangent plane, so the
  terrain is shifted by `package height − scene height` (`origin_offset`); `height_at` includes it;
- different latitude / longitude: a warning (`origin_warning`); the terrain is not moved, because a different
  tangent plane is a rotation, not a shift. Rebuild the package at the scene origin.

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
- Close to the ground the picture is limited by the data (30 m DEM, 10 m imagery), not by the renderer; a detail
  texture from ESA WorldCover is planned for v0.2.
