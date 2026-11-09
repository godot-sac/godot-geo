# Compatibility

What each godot-geo version was actually run on. "Not tested" means exactly that: it may well work, but nobody
has tried it. Reports for other combinations are welcome (open an issue with the Godot version, OS, GPU and the
output of the tests).

## Addon (`addons/geo/`)
The addon is GDScript using engine APIs only (no GDExtension, no compiled code), so it is the same on every
platform Godot runs on.

| godot-geo | Godot | Platform | Renderer | Tested | Result |
|---|---|---|---|---|---|
| 0.2.0 | 4.7.2 stable | Windows 11 x86_64 (NVIDIA RTX 4080, Vulkan) | Forward+ | GUT 76, pytest 242; Üsküdar 10 km and 60 km packages with bridges, `city.tscn --check` and `--tour` | pass |
| 0.2.0 | 4.7.2 stable | Windows, Linux (GitHub Actions) | headless | GUT, pytest, release zips in an empty project | pass |
| 0.1.0 | 4.7.2 stable | Windows 11 x86_64 (NVIDIA RTX 4080, Vulkan) | Forward+ | GUT 47 tests; release zips in an empty project (`tools/check_package.py`) with the sample and Ankara packages; demos `visibility.tscn --check`, `terrain_view.tscn`, `dis3d.tscn --check`; the getting-started scene | pass |
| 0.1.0 | 4.7.2 stable | Windows 11 x86_64 | Mobile, Compatibility (OpenGL 3.3) | the getting-started scene with line of sight and viewshed overlay (picture checked) | pass |
| 0.1.0 | 4.7.2 stable | Linux x86_64 (Ubuntu 24.04 on WSL2) | headless | GUT on a clean clone (46 pass, 1 pending: the godot-dis integration test without godot-dis linked); release zips in an empty project (`tools/check_package.py`); the getting-started guide followed from scratch | pass |
| 0.1.0 | 4.7.2 stable | macOS | — | not tested | — |
| 0.1.0 | 4.3 – 4.6 | any | — | not tested; the addon only uses APIs that exist since 4.3 | — |

Exported games: packages are read from the file system (`FileAccess`, `Image.load_from_file`), and `terrain/` is
excluded from import by `.gdignore`, so the export does not contain them. Ship the package folder next to the
executable with the same relative path: in an exported game a `res://` path that is not in the `.pck` is looked up
in the executable's folder, so `package_path = "res://terrain/<name>"` keeps working (an absolute path works too).
Tested with Godot 4.7.2 release templates on Windows and Linux (2026-11-09, release zip 0.1.0, buildings, trees,
roads, line of sight; in godot-sim-demo, see godot-sim-demo's [export guide](https://github.com/godot-sac/godot-sim-demo/blob/main/docs/export.md)).

## Package builder (`tools/build_terrain.py`)
| godot-geo | Python | Platform | Tested | Result |
|---|---|---|---|---|
| 0.1.0 | 3.13 | Windows 11 | pytest 213 tests (GDAL, PROJ and pymap3d references), the Ankara, Fiji and Norway packages, the release packages | pass |
| 0.1.0 | 3.12 | Ubuntu 24.04 (WSL2) | pytest on a clean clone (208 pass, 1 skipped: needs the locally built Ankara package) | pass |
| 0.1.0 | 3.12 | macOS | not tested | — |

Package format version 1 (`terrain.json` `format_version`); packages built by any 0.1.x builder load in any 0.1.x
addon.

## Sibling modules
`demo/dis3d.tscn` and the `DisGeoOrigin` alignment were tested with the godot-dis and godot-milsymbol working trees
of the same date (both unreleased, 0.1.0). The addon itself does not need them.
