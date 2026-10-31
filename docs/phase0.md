# Phase 0 findings (2026-10-31)

Exploration before the terrain package format and the renderer are fixed. Everything here is reproducible with the
scripts in `tools/probe_*.py`, `tools/prototype_package.py` and `prototypes/phase0/`.

## Copernicus DEM GLO-30, Ankara tile
`Copernicus_DSM_COG_10_N39_00_E032_00_DEM.tif` (AWS `copernicus-dem-30m`, 39.9 MB,
SHA-256 `40191d3c13d952509da7d3f92df29cfeeb07832abb4289e6e985ded0c6825055`):

| Property | Value |
|---|---|
| CRS | EPSG:4326 (horizontal only; the file carries **no vertical CRS**) |
| Size / step | 3600 × 3600, 1 arc-second |
| Pixel alignment | `AREA_OR_POINT=Point`: pixel centres on whole arc-seconds, row 0 = 40°N, col 0 = 32°E; tiles abut without overlap |
| Data type / nodata | float32, no nodata value (sea would be 0) |
| Overviews | 2, 4, 8 |

Vertical datum: the product documentation states EGM2008; the file itself does not say. Checked empirically: at the
Esenboğa ARP (40°07'41"N 32°59'42"E, published elevation 952.5 m AMSL) the DEM gives 948.2 m. Ellipsoidal heights
would read ~990 m (N ≈ +37 m), so the values are orthometric. The 4 m gap is expected: the published figure is the
highest runway point, and GLO-30 is a surface model with ~2–4 m vertical noise.

Above 50° latitude GLO-30 tiles become narrower in longitude; the prototype asserts 3600 × 3600 and must handle
this in Phase 1 if other regions are wanted.

## Geoid
PROJ `us_nga_egm08_25.tif` (NGA EGM2008 2.5' grid, public domain), fetched on demand through the PROJ CDN
(`pyproj.network`). Pipeline `EPSG:4979 → EPSG:4326+3855`.

| Point | N (m) |
|---|---|
| NGA EGM2008 test point 38.6281550 N, 269.7791550 E | −31.702 (NGA reference −31.628; 7 cm is the 2.5' grid interpolation error) |
| Ankara origin 39.9334 N, 32.8597 E | +37.195 |
| 40 × 40 km box around the origin | +36.99 … +37.43 |

So `h_ellipsoid = H_DEM + N`, with N ≈ 37.2 m and nearly constant over the area. Without this correction DIS entities
(which carry ellipsoidal ECEF positions) would float 37 m below the terrain.

## Sentinel-2 L2A
Earth Search STAC, collection `sentinel-2-l2a`, summer 2025, cloud < 2 %: **13 scenes** for the 20 km window (the
85 counted during planning were for a larger search). All on MGRS tile **36TVK** (UTM 36N, EPSG:32636); a
40 × 40 km area around the origin fits in this one tile, so no mosaicking is needed for Ankara.

Chosen: `S2B_36TVK_20250729_0_L2A` (cloud 0.0008 %). Reading only the needed window of the `visual` (TCI) COG over
HTTP range requests: 2000 × 2000 px in ~20 s, 4015 × 4015 px in ~21 s. Colours are usable without correction; see
`phase0/s2_ankara_20km.jpg`.

## Prototype package
`tools/prototype_package.py`: 40 × 40 km, 10 m grid (4001²), ~60 s including downloads. Each grid point (e, n) is
solved iteratively for the terrain surface point with those ENU coordinates (geoid + curvature included);
converges to 0.5 mm in 4 iterations. Heights (ENU up, origin at ellipsoidal height 0): 797–1874 m.

## Renderer comparison
Same package, same scene (sun, sky, fog), same camera views, 1920 × 1080, RTX 4080, vsync off. Screenshots:
`phase0/comparison_sheet.jpg` (left: own mesh, right: Terrain3D).

| | Own chunked mesh (prototype) | Terrain3D 1.1.0 |
|---|---|---|
| Code | ~150 lines GDScript + 40 lines shader | external GDExtension (45 MB release zip, all platforms) |
| Load (read + build) | 0.34 s | 0.76 s (`import_images`) |
| Frame time, 5 views | 0.69–0.96 ms | 0.61–0.84 ms |
| Triangles in frame | 0.35–3.9 M | 0.24–1.06 M |
| Video memory | 420 MB | 373 MB |
| Heights vs package | exact (same texture) | exact at grid points (0.0000 m over 2000 samples) |
| LOD | 4 fixed levels via visibility ranges, skirts | geometry clipmap, continuous |
| Collision | not yet (HeightMapShape3D, simple) | built in |
| Area limit | one texture: ~16k² samples | 65 km+ per terrain, regions |
| Extras | — | editor sculpting, texture splatting, foliage instancer, navigation |
| Godot version | 4.3+ possible | 4.5+ |

Visually the two are indistinguishable with this data: detail is limited by the data (30 m DEM, 10 m colour), not
by the renderer. The low view (60 m above ground) shows that limit plainly for both.

Note on heights between grid points: Terrain3D's `get_height()` at cell centres differs from the bilinear mean of
the four corners by up to 6.9 m on steep cells: it follows its own triangulation. A ground-clamping query must use
the same interpolation as the drawn surface, whichever renderer is chosen.
