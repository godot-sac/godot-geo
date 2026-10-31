"""Links the sibling repositories the 3D DIS demo (demo/dis3d.tscn) needs into this project:

    addons/dis        <- ../godot-dis/addons/dis          (DIS GDExtension; build it there first)
    addons/milsymbol  <- ../godot-milsymbol/addons/milsymbol
    demo/dis          <- ../godot-dis/demo                 (its scenario, unit mover and tactical map)

Directory junctions on Windows (no admin rights or developer mode needed), symbolic links elsewhere; all three are
git-ignored. The terrain addon and its tests work without them.

Usage (from the repo root, any Python 3): python tools/link_siblings.py [--workspace ..]
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

LINKS = [
    ("addons/dis", "godot-dis/addons/dis"),
    ("addons/milsymbol", "godot-milsymbol/addons/milsymbol"),
    ("demo/dis", "godot-dis/demo"),
]


def link(target: Path, source: Path) -> None:
    if os.name == "nt":
        subprocess.run(["cmd", "/c", "mklink", "/J", str(target), str(source)], check=True,
                       stdout=subprocess.DEVNULL)
    else:
        target.symlink_to(source, target_is_directory=True)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workspace", type=Path, default=root.parent, help="folder holding the sibling repos")
    args = parser.parse_args()
    for target_rel, source_rel in LINKS:
        target = root / target_rel
        source = (args.workspace / source_rel).resolve()
        if target.exists() or target.is_symlink():
            print(f"{target_rel} already exists")
            continue
        if not source.is_dir():
            print(f"missing {source}; clone the sibling repository next to this one", file=sys.stderr)
            return 1
        link(target, source)
        print(f"linked {target_rel} -> {source}")
    print("Run once so Godot registers the classes: <godot> --headless --path . --import")
    return 0


if __name__ == "__main__":
    sys.exit(main())
