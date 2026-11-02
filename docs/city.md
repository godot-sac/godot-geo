# City view (Üsküdar, Istanbul)

`demo/city.tscn` shows a terrain package with its layers and jumps between named camera bookmarks, so the picture
can be compared with places one knows. The default area is Üsküdar on the Asian shore of the Bosphorus. Layers are
being added one at a time (water first; ground textures, trees, buildings and roads follow), each checked on a
10 × 10 km package before the 60 × 60 km one.

## Packages
Both packages share one origin, 41.0200 N 29.0500 E (ellipsoidal height 0), so scene coordinates do not change
between them. Commands from the repository root (Git Bash; see the README for the virtual environment):

```bash
tools/.venv/Scripts/python.exe -I tools/build_terrain.py --lat 41.02 --lon 29.05 --size 10000 --spacing 5 \
    --color-spacing 10 --scene S2A_35TPF_20250722_0_L2A --layers water --water-spacing 2.5 \
    --out terrain/uskudar_10km
```

About 35 s the first time (Copernicus DEM tile, Sentinel-2 window, Overture water polygons), a few seconds from the
cache. Heights 5 m (from the 30 m DEM), colour 10 m, water mask 2.5 m. The 60 km package uses the same command with
`--size 60000 --spacing 10` and comes later with its layers.

`tests/data/uskudar_small` (3 km around the Üsküdar seafront, origin 41.024 N 29.012 E) is the committed test
package: `--lat 41.024 --lon 29.012 --size 3000 --spacing 15 --color-spacing 15 --layers water --water-spacing 7.5`.

## Running
```bash
<godot> --path . res://demo/city.tscn [-- --package <dir>] [--place <id>]
<godot> --path . res://demo/city.tscn -- --tour --out <dir>
tools/.venv/Scripts/python.exe demo/places_sheet.py <dir> <dir>/sheet.jpg [--only-checks]
```

| Key | |
|---|---|
| right mouse + WASD, Q / E | fly; Shift = 5× faster, mouse wheel = speed |
| Tab | bookmark list (click to go) |
| 1–9, 0 | bookmarks in list order |
| PgUp / PgDn | previous / next bookmark |
| G / F | drop to 2 m above the ground / walk on the ground |
| F3 | position (WGS84, MGRS), height above ground, water, frame rate |
| F12 | screenshot to `user://` |

`--tour` visits every bookmark inside the package, saves `<id>.png` and `stats.json` (frame time, primitives, draw
calls, video memory) and quits.

## Bookmarks
`demo/places.json`: id, name, target point (latitude, longitude, `target_height` above the ground), camera heading
(degrees from north), pitch (negative = down) and distance. Positions come from OpenStreetMap through Overture Maps.
Three are reference views for visual checks (`"check": true`): Bulgurlu (İzzettinbey Parkı), Capitol shopping
centre in Altunizade, and the Üsküdar seafront. The others: Kız Kulesi, the Küçük Çamlıca TV tower, Büyük Çamlıca
mosque, the 15 Temmuz Şehitler bridge, Kuzguncuk, Beylerbeyi Palace and an overview. Military sites are never
bookmarked.

## Measurements
10 km package, 1600 × 900, RTX 4080, terrain and water only (`lod_distance` 6): 0.8–1.2 ms per frame at the
bookmarks, up to 5.4 M primitives, 27–63 draw calls, 261 MB video memory; load 0.2 s.
