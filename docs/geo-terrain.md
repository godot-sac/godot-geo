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

## Alignment with godot-dis
If the scene has a node in group `dis_geo_origin` (godot-dis `DisGeoOrigin`) — godot-geo does not depend on
godot-dis, it reads `latitude`, `longitude`, `height` by name:
- same latitude / longitude (within 1e-7°, ~1 cm), different height: both frames share the tangent plane, so the
  terrain is shifted by `package height − scene height` (`origin_offset`); `height_at` includes it;
- different latitude / longitude: a warning (`origin_warning`); the terrain is not moved, because a different
  tangent plane is a rotation, not a shift. Rebuild the package at the scene origin.

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
- Packages are read from the file system (`res://` in the editor, absolute paths); exported games need the package
  next to the executable. One package at a time, no streaming.
- Close to the ground the picture is limited by the data (30 m DEM, 10 m imagery), not by the renderer; a detail
  texture from ESA WorldCover is planned for v0.2.
