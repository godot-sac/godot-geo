# 3D DIS demo

`demo/dis3d.tscn` is one participant of the godot-dis two-sided exercise around Ankara, shown in 3D on real terrain.
It publishes its own units with godot-dis `DisEntity` and shows everything else on the network: the other side (the
godot-dis 2D demo, or a second 3D copy) and civilian traffic sent by an independent DIS implementation
(Open-DIS Python). Units are simple models plus MIL-STD-2525 symbols (godot-milsymbol); the godot-dis tactical map
is the minimap.

![3D DIS demo: blue, red and civilian units around Ankara](demo3d/overview.jpg)

## Setup (once)
The demo uses the sibling repositories of the workspace; `tools/link_siblings.ps1` links them in as directory
junctions (git-ignored): `addons/dis`, `addons/milsymbol` and `demo/dis` (the godot-dis demo's scenario, unit mover
and tactical map, so both demos run the same exercise).

```powershell
cd path\to\godot-geo
.\tools\link_siblings.ps1
.\tools\.venv\Scripts\python.exe -I tools\build_terrain.py --lat 39.9334 --lon 32.8597 --size 60000 --spacing 15 --out terrain\ankara_60km
```
godot-dis must be built (`addons/dis/bin`). The exercise spans about ±27 km, hence the 60 km package; without it the
demo falls back to `terrain/ankara` (40 km) and units beyond its edge keep their reported height.

## Run
Blue in 3D, red in the godot-dis 2D demo, civilian traffic from Python (three terminals):
```powershell
cd path\to\godot-geo; & "C:\path\to\godot.exe" --path . res://demo/dis3d.tscn -- --side blue
cd path\to\godot-dis; & "C:\path\to\godot.exe" --path . res://demo/main.tscn -- --side red
cd path\to\godot-dis; .\tools\.venv\Scripts\python.exe tools\demo_traffic.py
```
Controls: Tab / Shift+Tab next / previous unit, left drag orbit, wheel zoom, C free camera (right mouse + WASD).
`-- --shots <dir> --warmup <s>` saves the views in this document and quits.

## How the units meet the ground
- **Own units:** `DemoUnitMover.ground = GeoTerrain`. Land units drive on `height_at` and tilt with the slope;
  aircraft keep at least 150 m above the ground. `DisEntity` publishes the result, so other simulations see the units
  on our terrain.
- **Remote units:** `DisEntityManager.ground_path = GeoTerrain`. Land platforms, life forms and cultural features are
  put on the local terrain and tilted to it (heading kept); aircraft keep their reported height. The 2D demo and the
  Python traffic send land units at the height of the tangent plane, so without the clamp they would be up to
  hundreds of metres under or above the hills.
- **Alignment:** the scene's `DisGeoOrigin` (39.9334, 32.8597, 938 m) has the package origin's latitude and longitude
  but another height, so `GeoTerrain` shifts the terrain by −938 m automatically (see geo-terrain.md).

## Views
| | |
|---|---|
| ![](demo3d/tank_close.jpg) own tank on the terrain | ![](demo3d/remote_tank.jpg) red tank from the 2D demo, clamped |
| ![](demo3d/helicopter.jpg) helicopter with its ground line | ![](demo3d/civilian.jpg) civilian traffic from Open-DIS Python |
| ![](demo3d/exercise.jpg) own tanks from 6 km | |

<sub>Contains modified Copernicus Sentinel data 2025. Elevation produced using Copernicus WorldDEM-30 © DLR e.V.
2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all
rights reserved. Enumerations: SISO-REF-010, reprinted with permission from SISO Inc.</sub>
