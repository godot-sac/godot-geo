"""Release zips (tools/package_release.py): layout, attribution, checksums. No network."""
import importlib.util
import json
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "tools" / "package_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def test_addon_zip_layout(tmp_path):
    names = zipfile.ZipFile(release.addon_zip("9.9.9", tmp_path)).namelist()
    assert all(n.startswith("addons/geo/") for n in names)
    assert "addons/geo/geo_terrain.gd" in names and "addons/geo/geo_terrain.gd.uid" in names
    assert "addons/geo/LICENSE" in names and "addons/geo/THIRD_PARTY_NOTICES.md" in names
    assert "addons/geo/VERSION.txt" in names
    assert not [n for n in names if n.endswith(".import")]


def test_sample_terrain_zip(tmp_path):
    packages = {n: ROOT / "tests" / "data" / n for n in release.SAMPLES}
    archive = zipfile.ZipFile(release.terrain_zip(tmp_path / "t.zip", packages))
    names = set(archive.namelist())
    assert "terrain/.gdignore" in names
    for n in release.SAMPLES:
        assert {f"terrain/{n}/{f}" for f in release.PACKAGE_FILES + ["ATTRIBUTION.txt"]} <= names
        meta = json.loads(archive.read(f"terrain/{n}/terrain.json"))
        text = archive.read(f"terrain/{n}/ATTRIBUTION.txt").decode("utf-8")
        for notice in meta["attribution"]:
            assert notice in text
    assert not [n for n in names if n.endswith(".import")]


def test_package_with_wrong_hash_is_refused(tmp_path):
    src = ROOT / "tests" / "data" / "ankara_small"
    copy = tmp_path / "pkg"
    copy.mkdir()
    for f in release.PACKAGE_FILES:
        (copy / f).write_bytes((src / f).read_bytes())
    (copy / "color.png").write_bytes(b"not the original")
    with pytest.raises(ValueError, match="SHA-256"):
        release.check_package(copy)
