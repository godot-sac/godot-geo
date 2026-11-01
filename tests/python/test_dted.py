"""Tests for tools/dted.py, the numpy-only DTED reader.

Run from the repo root:  tools/.venv/Scripts/python.exe -m pytest tests/python/test_dted.py
Oracles are independent of the code under test:
  - GDAL's DTED driver (through rasterio) WRITES the files from a synthetic surface and READS them back;
  - sample() is compared with GDAL's own bilinear resampling (rasterio fractional-window read);
  - a tiny writer in this file builds hand-made records for the byte-level cases (sign-magnitude, checksums,
    truncation, non-square cells).
"""
from __future__ import annotations

import struct
import sys
import warnings
from pathlib import Path

import numpy as np
import pytest
import rasterio
import rasterio.shutil
from rasterio.enums import Resampling
from rasterio.io import MemoryFile
from rasterio.transform import Affine
from rasterio.windows import Window

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import dted  # noqa: E402

GDAL_VOID = -32767

# (id, lat of SW post, lon of SW post, posts in latitude, posts in longitude, expected series, expected dlon in arcsec)
# GDAL picks the longitude interval from the latitude itself (3" below 50, 6" below 65, 9" below 70, 18" from 75),
# so the file shapes below are the ones its DTED driver accepts without resampling.
GDAL_CELLS = [
    pytest.param(40, 30, 1201, 1201, "DTED1", 3.0, id="level1_lat40"),
    pytest.param(60, 30, 1201, 601, "DTED1", 6.0, id="level1_lat60"),
    pytest.param(70, 30, 1201, 401, "DTED1", 9.0, id="level1_lat70"),
    pytest.param(80, 30, 1201, 201, "DTED1", 18.0, id="level1_lat80"),
    pytest.param(40, 30, 121, 121, "DTED0", 30.0, id="level0_lat40"),
    pytest.param(-34, -71, 1201, 1201, "DTED1", 3.0, id="level1_south_west"),
]


# --- GDAL-written files -----------------------------------------------------------------------------------------

def surface(nlat: int, nlon: int) -> np.ndarray:
    """Smooth synthetic heights, -400 .. 2400 m, row 0 = north; a few voids; int16 like a DTED cell."""
    v, u = np.meshgrid(np.linspace(0, 1, nlat), np.linspace(0, 1, nlon), indexing="ij")
    z = 1000 + 900 * np.sin(2 * np.pi * 1.3 * u + 0.4) * np.cos(2 * np.pi * 0.9 * v) \
        + 500 * np.sin(2 * np.pi * 3 * (u + v))
    z = np.rint(z).astype(np.int16)
    assert z.min() < 0
    z[nlat // 3, nlon // 2] = GDAL_VOID
    z[nlat // 3 + 1, nlon // 2] = GDAL_VOID
    z[0, 0] = GDAL_VOID
    z[-1, -1] = GDAL_VOID
    return z


def gdal_write_dted(path: Path, lat0: float, lon0: float, nlat: int, nlon: int) -> np.ndarray:
    """Write a 1x1 degree cell with GDAL's DTED driver; returns the array that was written (row 0 = north).

    Posts are points, so the GeoTIFF geotransform origin is half a post outside the first post centre.
    """
    z = surface(nlat, nlon)
    dlat, dlon = 1.0 / (nlat - 1), 1.0 / (nlon - 1)
    transform = Affine(dlon, 0, lon0 - dlon / 2, 0, -dlat, lat0 + 1 + dlat / 2)
    with MemoryFile() as mem:
        with mem.open(driver="GTiff", width=nlon, height=nlat, count=1, dtype="int16", crs="EPSG:4326",
                      transform=transform, nodata=GDAL_VOID) as ds:
            ds.write(z, 1)
        with mem.open() as src:
            rasterio.shutil.copy(src, str(path), driver="DTED")
    return z


@pytest.fixture(scope="module")
def gdal_cell(tmp_path_factory):
    """Writes each GDAL cell once per test module."""
    cache: dict = {}

    def get(lat0, lon0, nlat, nlon):
        key = (lat0, lon0, nlat, nlon)
        if key not in cache:
            p = tmp_path_factory.mktemp("dted") / f"cell_{lat0}_{lon0}_{nlat}x{nlon}.dt"
            cache[key] = (p, gdal_write_dted(p, lat0, lon0, nlat, nlon))
        return cache[key]
    return get


@pytest.mark.parametrize("lat0,lon0,nlat,nlon,series,dlon_arcsec", GDAL_CELLS)
def test_matches_gdal_read(gdal_cell, lat0, lon0, nlat, nlon, series, dlon_arcsec):
    path, written = gdal_cell(lat0, lon0, nlat, nlon)
    cell = dted.read_dted(path)
    with rasterio.open(path) as ds:
        g = ds.read(1).astype(np.float64)
        nodata, tr = ds.nodata, ds.transform
    g[g == nodata] = np.nan

    assert cell.level == series
    assert cell.data.dtype == np.float32
    assert cell.data.shape == (nlat, nlon) == g.shape
    assert cell.checksum_errors == 0
    assert (cell.vertical_datum, cell.horizontal_datum) == ("MSL", "WGS84")
    np.testing.assert_array_equal(np.isnan(cell.data), np.isnan(g))
    np.testing.assert_array_equal(cell.data, g.astype(np.float32))  # identical post for post
    # and the file really holds what we asked GDAL to write
    exp = written.astype(np.float32)
    exp[exp == GDAL_VOID] = np.nan
    np.testing.assert_array_equal(cell.data, exp)
    assert np.nanmin(cell.data) < 0

    # origin and spacing equal the GDAL geotransform once its half-post shift is removed
    assert cell.dlon == pytest.approx(tr.a, abs=1e-12) and cell.dlon == pytest.approx(dlon_arcsec / 3600, abs=1e-12)
    assert cell.dlat == pytest.approx(-tr.e, abs=1e-12)
    assert cell.lon0 == pytest.approx(tr.c + tr.a / 2, abs=1e-9) == pytest.approx(lon0, abs=1e-9)
    assert cell.lat_of_row(0) == pytest.approx(tr.f + tr.e / 2, abs=1e-9) == pytest.approx(lat0 + 1, abs=1e-9)
    assert cell.lat_of_row(nlat - 1) == pytest.approx(lat0, abs=1e-9)
    assert cell.lon_of_col(nlon - 1) == pytest.approx(lon0 + 1, abs=1e-9)
    assert cell.lat0 == pytest.approx(lat0, abs=1e-9)


@pytest.mark.parametrize("lat0,lon0,nlat,nlon,series,dlon_arcsec", GDAL_CELLS)
def test_sample_matches_gdal_bilinear(gdal_cell, lat0, lon0, nlat, nlon, series, dlon_arcsec):
    path, _ = gdal_cell(lat0, lon0, nlat, nlon)
    cell = dted.read_dted(path)
    rng = np.random.default_rng(7)
    lat = lat0 + rng.uniform(0.002, 0.998, 300)
    lon = lon0 + rng.uniform(0.002, 0.998, 300)
    ours = cell.sample(lat, lon)
    ok = np.isfinite(ours)
    assert ok.sum() > 250  # only the few points next to voids drop out

    # GDAL resamples in the source data type (int16 rounds), so give it a float32 copy of what it read from the file
    with rasterio.open(path) as src, MemoryFile() as mem:
        with mem.open(driver="GTiff", width=src.width, height=src.height, count=1, dtype="float32",
                      crs=src.crs, transform=src.transform, nodata=src.nodata) as ds:
            ds.write(src.read(1).astype(np.float32), 1)
        with mem.open() as ds:
            inv = ~ds.transform
            for i in np.flatnonzero(ok)[:150]:
                x, y = inv @ (lon[i], lat[i])
                win = Window(x - 0.5, y - 0.5, 1, 1)
                ref = float(ds.read(1, window=win, out_shape=(1, 1), resampling=Resampling.bilinear)[0, 0])
                assert ours[i] == pytest.approx(ref, abs=1e-3)


def test_sample_edges_voids_and_outside(gdal_cell):
    path, _ = gdal_cell(40, 30, 1201, 1201)
    cell = dted.read_dted(path)
    # exactly on posts (corners, edges, interior) returns the post value
    rows, cols = np.array([2, 1, 600, 1200 - 1]), np.array([2, 1199, 600, 5])
    got = cell.sample(cell.lat_of_row(rows), cell.lon_of_col(cols))
    np.testing.assert_allclose(got, cell.data[rows, cols], atol=1e-3)
    # the cell edges are inside, just beyond them is not
    d = cell.data
    south_edge = cell.sample(np.array([cell.lat_of_row(1200)]), np.array([cell.lon_of_col(1)]))[0]
    assert south_edge == pytest.approx(d[1200, 1])
    assert np.isnan(cell.sample(np.array([30.0]), np.array([30.5]))).all()
    assert np.isnan(cell.sample(np.array([41.0001]), np.array([30.5]))).all()
    assert np.isnan(cell.sample(np.array([40.5]), np.array([29.9999]))).all()
    assert np.isnan(cell.sample(np.array([40.5]), np.array([31.0001]))).all()
    # a void post poisons every cell quad that touches it; the quad not touching it is fine
    r, c = 1200 // 3, 1200 // 2
    assert np.isnan(d[r, c])
    lat_v, lon_v = cell.lat_of_row(r), cell.lon_of_col(c)
    assert np.isnan(cell.sample(np.array([lat_v]), np.array([lon_v]))).all()
    assert np.isnan(cell.sample(np.array([lat_v + 0.3 * cell.dlat]), np.array([lon_v - 0.4 * cell.dlon]))).all()
    assert np.isfinite(cell.sample(np.array([lat_v + 5 * cell.dlat]), np.array([lon_v]))).all()


def test_level2_gdal_file(tmp_path):
    """Level 2 (1 arc second, 3601 x 3601) is the largest file GDAL's driver writes; check it reads identically."""
    path = tmp_path / "l2.dt2"
    gdal_write_dted(path, 40, 30, 3601, 3601)
    cell = dted.read_dted(path)
    with rasterio.open(path) as ds:
        g = ds.read(1).astype(np.float32)
        g[g == ds.nodata] = np.nan
    assert cell.level == "DTED2"
    assert cell.dlat == pytest.approx(1 / 3600, abs=1e-12)
    np.testing.assert_array_equal(cell.data, g)


# --- hand-written files -----------------------------------------------------------------------------------------

def _angle_field(value: float, pos: str, neg: str) -> bytes:
    a = abs(value)
    d, m, s = int(a), int(a * 60) % 60, int(round(a * 3600)) % 60
    return f"{d:03d}{m:02d}{s:02d}{pos if value >= 0 else neg}".encode()


def write_dted(path: Path, lat0: float, lon0: float, dlat_tenths: int, dlon_tenths: int, lines: list[list[int]],
               series: bytes = b"DTED1") -> bytes:
    """Minimal DTED writer. `lines` = one list of raw 16-bit words per longitude line (west to east, south to
    north in each). Returns the bytes written."""
    nlon, nlat = len(lines), len(lines[0])
    uhl = bytearray(b" " * 80)
    uhl[0:4] = b"UHL1"
    uhl[4:12] = _angle_field(lon0, "E", "W")
    uhl[12:20] = _angle_field(lat0, "N", "S")
    uhl[20:24] = f"{dlon_tenths:04d}".encode()
    uhl[24:28] = f"{dlat_tenths:04d}".encode()
    uhl[28:32] = b"NA  "
    uhl[47:51] = f"{nlon:04d}".encode()
    uhl[51:55] = f"{nlat:04d}".encode()
    dsi = bytearray(b" " * 648)
    dsi[0:3] = b"DSI"
    dsi[59:64] = series
    dsi[141:144] = b"MSL"
    dsi[144:149] = b"WGS84"
    acc = bytearray(b" " * 2700)
    acc[0:3] = b"ACC"
    out = bytearray(uhl + dsi + acc)
    for i, words in enumerate(lines):
        rec = bytearray([0xAA]) + i.to_bytes(3, "big") + struct.pack(">HH", i, 0)
        rec += struct.pack(f">{nlat}H", *words)
        rec += struct.pack(">I", sum(rec))
        out += rec
    path.write_bytes(out)
    return bytes(out)


def sm(v: int) -> int:
    """Sign-magnitude word for a height."""
    return (0x8000 | -v) if v < 0 else v


def test_sign_magnitude_and_voids(tmp_path):
    p = tmp_path / "t.dt1"
    lines = [[0x0005, 0x8005, 0xFFFF], [0x7FFF, 0xFFFF, 0x8001], [0x0000, 0x8000, sm(-1234)]]
    write_dted(p, 10.0, 20.0, 30, 30, lines)
    c = dted.read_dted(p)
    assert c.data.shape == (3, 3)
    # row 0 = north = last word of each line; column 0 = west = first line
    by_line = np.array([[5, -5, np.nan], [32767, np.nan, -1], [0, np.nan, -1234]], dtype=np.float32)
    exp = by_line.T[::-1]
    np.testing.assert_array_equal(c.data, exp)
    assert c.data[2, 0] == 5 and c.data[1, 0] == -5  # 0x0005 -> 5, 0x8005 -> -5 (not two's complement -32763)
    assert np.isnan(c.data[0, 0])  # 0xFFFF = -32767 void
    assert np.isnan(c.data[1, 2])  # 0x8000 = -32768 (some writers) also void
    assert c.data[0, 2] == -1234
    assert c.checksum_errors == 0
    assert (c.level, c.vertical_datum, c.horizontal_datum) == ("DTED1", "MSL", "WGS84")


def test_non_square_cell_shape_and_coordinates(tmp_path):
    # high-latitude style: 6" x 3" posts, 5 longitude lines x 3 latitude points, western/southern hemispheres
    p = tmp_path / "hl.dt1"
    lines = [[sm(100 * i + j) for j in range(3)] for i in range(5)]
    write_dted(p, -72.0, -105.0, 30, 60, lines)
    c = dted.read_dted(p)
    assert c.data.shape == (3, 5)
    assert (c.nlat, c.nlon) == (3, 5)
    assert c.lat0 == pytest.approx(-72.0) and c.lon0 == pytest.approx(-105.0)
    assert c.dlat == pytest.approx(3 / 3600) and c.dlon == pytest.approx(6 / 3600)
    assert c.lat_of_row(0) == pytest.approx(-72.0 + 2 * 3 / 3600)
    assert c.lat_of_row(2) == pytest.approx(-72.0)
    assert c.lon_of_col(4) == pytest.approx(-105.0 + 4 * 6 / 3600)
    for i in range(5):
        for j in range(3):
            assert c.data[2 - j, i] == 100 * i + j
    # bilinear midpoint of the four posts around (lat row 1..2, lon col 2..3)
    lat = (c.lat_of_row(1) + c.lat_of_row(2)) / 2
    lon = (c.lon_of_col(2) + c.lon_of_col(3)) / 2
    assert c.sample(np.array([lat]), np.array([lon]))[0] == pytest.approx(np.mean(c.data[1:3, 2:4]), abs=1e-4)
    # inference of the level from the intervals when the DSI series is blank
    write_dted(p, 10.0, 20.0, 300, 300, [[1, 2], [3, 4]], series=b"     ")
    assert dted.read_dted(p).level == "DTED0"
    write_dted(p, 10.0, 20.0, 10, 10, [[1, 2], [3, 4]], series=b"     ")
    assert dted.read_dted(p).level == "DTED2"


def test_bad_checksum_is_counted_and_warned(tmp_path):
    p = tmp_path / "ck.dt1"
    lines = [[sm(i * 10 + j) for j in range(4)] for i in range(6)]
    raw = bytearray(write_dted(p, 10.0, 20.0, 30, 30, lines))
    rec_size = 8 + 2 * 4 + 4
    raw[3428 + 2 * rec_size + 9] ^= 0x01  # flip one bit of an elevation in line 2
    raw[3428 + 4 * rec_size + 11] ^= 0x10  # and one in line 4
    p.write_bytes(raw)
    with pytest.warns(UserWarning, match="2 of 6 data records have a bad checksum"):
        c = dted.read_dted(p)
    assert c.checksum_errors == 2
    assert c.data.shape == (4, 6) and np.isfinite(c.data).all()  # data is still returned (corrupted values kept)
    assert c.data[3, 2] != 20  # the flipped bit is visible: this is the post that was damaged
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        assert dted.read_dted(p, verify_checksums=False).checksum_errors == 0


def test_corrupt_files_raise_value_error(tmp_path):
    p = tmp_path / "bad.dt1"
    good = write_dted(p, 10.0, 20.0, 30, 30, [[1, 2, 3]] * 4)
    rec_size = 8 + 2 * 3 + 4

    def expect(data: bytes, match: str):
        p.write_bytes(data)
        with pytest.raises(ValueError, match=match):
            dted.read_dted(p)

    expect(good[:-5], "truncated")  # cut inside the last record
    expect(good[:3428 + rec_size], "truncated")  # missing whole records
    expect(good[:100], "shorter than")
    expect(good + b"\0\0", "trailing")
    expect(b"XXXX" + good[4:], "UHL1")
    expect(good[:80] + b"XXX" + good[83:], "DSI")
    expect(good[:80 + 648] + b"XXX" + good[80 + 648 + 3:], "ACC")
    bad_sentinel = bytearray(good)
    bad_sentinel[3428 + rec_size] = 0x55
    expect(bytes(bad_sentinel), "data record 1 has sentinel 0x55")
    bad_field = bytearray(good)
    bad_field[47:51] = b"zz12"
    expect(bytes(bad_field), "line count")
    bad_origin = bytearray(good)
    bad_origin[4:12] = b"0200000X"
    expect(bytes(bad_origin), "longitude origin")
