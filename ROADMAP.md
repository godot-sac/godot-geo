# Roadmap

Where godot-geo is heading after 0.1.0. Nothing here is promised for a date; issues and pull requests that move an
item forward are welcome.

## Next
- **Own footprint files:** buildings from a footprint file (GeoPackage, Shapefile) besides OpenStreetMap extracts.
- **Bridges:** towers and deck height for bridges OpenStreetMap does not describe (the Yavuz Sultan Selim bridge);
  cable-stayed bridges.
- **Media:** an animation of the Üsküdar city view for the README.
- **Measurements:** a long flight along the Bosphorus in the benchmark; numbers on more GPUs.

## Later
- Reading DTED / GeoTIFF inside the engine (today a package is built offline by `tools/build_terrain.py`).
- Streaming of areas larger than one package (several packages, or tiles loaded around the camera).
- Bathymetry for water areas (e.g. EMODnet), so the sea floor is not flat.
- Faster visibility queries (C++ / GDExtension) for many sensors per frame.
- Tested support for Godot 4.3–4.6 and macOS.
- Using 3D Tiles for Godot alongside a package (shared origin; described in the docs but not tried).

## Known limits
See [Limits](docs/geo-terrain.md#limits-v01) and the accuracy notes in [city view](docs/city.md).
