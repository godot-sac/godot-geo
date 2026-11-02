"""Installs the release zips into a new, empty Godot project and uses the addon there: the check that a user who only
has the release assets gets a working addon (classes registered, package found, queries answer, no import errors).

Usage (from the repo root, any Python 3):
    python tools/check_package.py build/release/godot-geo-dev.zip build/release/godot-geo-terrain-samples.zip \
        --godot <path to the Godot executable> [--package ankara_small]
Prints a PACKAGE_CHECK line; exit code 1 on failure.
"""
import argparse
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

PROJECT = """config_version=5

[application]
config/name="godot-geo package check"
"""

SMOKE = """extends SceneTree

func _initialize() -> void:
	_run()


func _run() -> void:
	var terrain := GeoTerrain.new()
	terrain.package_path = "res://terrain/%s"
	root.add_child(terrain)
	await process_frame  # _ready() (which loads the package) runs only after _initialize()
	var ok := terrain.is_loaded()
	if ok:
		var size := terrain.package.size_m
		var a := Vector3(-0.2 * size, 0.0, 0.1 * size)
		var b := Vector3(0.25 * size, 0.0, -0.15 * size)
		a.y = terrain.height_at(a.x, a.z) + 10.0
		b.y = terrain.height_at(b.x, b.z) + 2.0
		var los := terrain.line_of_sight(a, b)
		var img := terrain.viewshed(a, 0.3 * size, 2.0, 64)
		terrain.set_overlay(GeoVisibility.viewshed_colors(img), terrain.viewshed_rect(a, 0.3 * size))
		var g := terrain.global_to_geodetic(a)
		print("origin ", terrain.package.meta.origin, "  height_at(0, 0) = ", terrain.height_at(0.0, 0.0))
		print("line of sight: ", los.visible, " clearance ", los.clearance, "  viewshed ", img.get_size())
		print("observer MGRS ", GeoMath.geodetic_to_mgrs(g[0], g[1]))
		print("attribution: ", "; ".join(terrain.attribution()))
		ok = not is_nan(a.y) and not is_nan(b.y) and los.has("visible") and img.get_width() == 64 \\
				and terrain.attribution().size() > 0
	print("PACKAGE_CHECK ", "ok" if ok else "FAILED")
	quit(0 if ok else 1)
"""

# Engine messages that mean the addon is broken in a fresh project (the first import must be clean).
PROBLEM = re.compile(r"^(SCRIPT ERROR|ERROR|WARNING|Parse Error)", re.M)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("zips", type=Path, nargs="+", help="addon zip and terrain zip")
    parser.add_argument("--godot", required=True)
    parser.add_argument("--package", default="", help="package under terrain/ to load (default: the first)")
    args = parser.parse_args()
    sys.stdout.reconfigure(errors="replace")  # the attribution has a (c) sign; some Windows consoles lack it

    with tempfile.TemporaryDirectory(prefix="ggeo-package-") as tmp:
        project = Path(tmp)
        (project / "project.godot").write_text(PROJECT, encoding="utf-8")
        for z in args.zips:
            with zipfile.ZipFile(z) as archive:
                archive.extractall(project)
        packages = sorted(p.parent.name for p in (project / "terrain").glob("*/terrain.json"))
        name = args.package or (packages[0] if packages else "")
        if name not in packages:
            print(f"PACKAGE_CHECK FAILED (no terrain package {name!r} in the zips: {packages})")
            return 1
        (project / "smoke.gd").write_text(SMOKE % name, encoding="utf-8")
        first = subprocess.run([args.godot, "--headless", "--path", str(project), "--import"],
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
        problems = PROBLEM.findall(first.stdout + first.stderr)
        print(f"import: exit {first.returncode}, {len(problems)} errors / warnings")
        if first.returncode != 0 or problems:
            print((first.stdout + first.stderr).strip()[-3000:], file=sys.stderr)
            print("PACKAGE_CHECK FAILED (the import was not clean)")
            return 1
        imported = sorted(p.relative_to(project).as_posix() for p in (project / "terrain").rglob("*.import"))
        if imported:
            print(f"PACKAGE_CHECK FAILED (the editor imported package files: {imported})")
            return 1
        run = subprocess.run([args.godot, "--headless", "--path", str(project), "-s", "res://smoke.gd"],
                             capture_output=True, text=True, encoding="utf-8", errors="replace")
        print(run.stdout.strip())
        problems = PROBLEM.findall(run.stdout + run.stderr)
        if run.returncode != 0 or problems:
            print(run.stderr.strip(), file=sys.stderr)
        if "PACKAGE_CHECK ok" not in run.stdout or problems:
            if "PACKAGE_CHECK" not in run.stdout:
                print("PACKAGE_CHECK FAILED (the script did not run)")
            elif problems:
                print("PACKAGE_CHECK FAILED (errors or warnings while running)")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
