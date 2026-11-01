"""Pure-Python (numpy only) reader for DTED level 0/1/2 cells (MIL-PRF-89020B), written from the format specification.

File layout (big-endian): UHL (80 bytes, "UHL1") + DSI (648, "DSI") + ACC (2700, "ACC") + one data record per
longitude line, west to east. A data record is: 0xAA sentinel, 3-byte block count, 2-byte longitude count, 2-byte
latitude count, `nlat` elevations south to north as 16-bit sign-magnitude values (bit 15 = sign, bits 0-14 =
magnitude, NOT two's complement), and a 4-byte checksum (sum of all preceding bytes of the record).

The longitude interval grows with latitude (zones at 50/70/75/80 degrees), so spacing and counts always come from the
UHL, never from the level. Posts are points (pixel-is-point): the origin is the centre of the south-west post.

Usage:
  cell = read_dted("n39_e032.dt1")
  z = cell.sample(lat, lon)        # bilinear, NaN outside the cell or next to a void
"""
from __future__ import annotations

import warnings
from dataclasses import dataclass
from pathlib import Path

import numpy as np

UHL_SIZE = 80
DSI_SIZE = 648
ACC_SIZE = 2700
HEADER_SIZE = UHL_SIZE + DSI_SIZE + ACC_SIZE
SENTINEL = 0xAA
RECORD_PREFIX = 8  # sentinel + block count + longitude count + latitude count
RECORD_SUFFIX = 4  # checksum
ARCSEC_TENTHS_PER_DEG = 36000.0
VOID_RAW = (0xFFFF, 0x8000)  # -32767 in sign-magnitude; 0x8000 is "-0" there, i.e. -32768 as written by some tools


@dataclass
class DtedCell:
    path: Path
    level: str  # "DTED0" / "DTED1" / "DTED2"
    lat0: float  # south-west corner post, degrees
    lon0: float
    dlat: float  # post spacing, degrees
    dlon: float
    data: np.ndarray  # float32 (nlat, nlon); row 0 = north edge, column 0 = west edge; voids = NaN
    vertical_datum: str
    horizontal_datum: str
    checksum_errors: int

    @property
    def nlat(self) -> int:
        return self.data.shape[0]

    @property
    def nlon(self) -> int:
        return self.data.shape[1]

    def lat_of_row(self, r):
        return self.lat0 + (self.nlat - 1 - np.asarray(r)) * self.dlat

    def lon_of_col(self, c):
        return self.lon0 + np.asarray(c) * self.dlon

    def sample(self, lat: np.ndarray, lon: np.ndarray) -> np.ndarray:
        """Bilinear height between posts. NaN outside the cell or if any of the 4 surrounding posts is void."""
        lat, lon = np.broadcast_arrays(np.asarray(lat, dtype=np.float64), np.asarray(lon, dtype=np.float64))
        r = (self.lat0 + (self.nlat - 1) * self.dlat - lat) / self.dlat  # fractional row, 0 = north post
        c = (lon - self.lon0) / self.dlon
        eps = 1e-9
        inside = (r >= -eps) & (r <= self.nlat - 1 + eps) & (c >= -eps) & (c <= self.nlon - 1 + eps)
        rr = np.where(inside, r, 0.0)
        cc = np.where(inside, c, 0.0)
        r0 = np.clip(np.floor(rr).astype(np.int64), 0, self.nlat - 2)
        c0 = np.clip(np.floor(cc).astype(np.int64), 0, self.nlon - 2)
        fr = rr - r0
        fc = cc - c0
        d = self.data
        top = d[r0, c0] * (1 - fc) + d[r0, c0 + 1] * fc
        bot = d[r0 + 1, c0] * (1 - fc) + d[r0 + 1, c0 + 1] * fc
        out = top * (1 - fr) + bot * fr
        return np.where(inside, out, np.nan)


def _ascii(b: bytes) -> str:
    return b.decode("ascii", errors="replace").strip("\x00 ")


def _int(b: bytes, what: str) -> int:
    try:
        return int(b.decode("ascii"))
    except ValueError:
        raise ValueError(f"DTED: bad {what} field {b!r}") from None


def _angle(b: bytes, what: str, pos: str, neg: str) -> float:
    """DDDMMSSH (degrees, minutes, seconds, hemisphere letter) to signed degrees."""
    s = b.decode("ascii", errors="replace")
    if len(s) != 8 or s[-1] not in pos + neg or not s[:-1].isdigit():
        raise ValueError(f"DTED: bad {what} field {b!r}")
    deg = int(s[0:3]) + int(s[3:5]) / 60.0 + int(s[5:7]) / 3600.0
    return deg if s[-1] in pos else -deg


def read_dted(path: str | Path, verify_checksums: bool = True) -> DtedCell:
    """Read a whole DTED cell. Raises ValueError on a corrupt or truncated file; checksum mismatches are counted in
    `checksum_errors` and warned about, not raised."""
    path = Path(path)
    buf = path.read_bytes()
    if len(buf) < HEADER_SIZE:
        raise ValueError(f"DTED: {path.name} is {len(buf)} bytes, shorter than the {HEADER_SIZE}-byte header")
    if buf[0:4] != b"UHL1":
        raise ValueError(f"DTED: {path.name} does not start with a UHL1 record (got {buf[0:4]!r})")
    if buf[UHL_SIZE:UHL_SIZE + 3] != b"DSI":
        raise ValueError(f"DTED: {path.name} has no DSI record after the UHL")
    if buf[UHL_SIZE + DSI_SIZE:UHL_SIZE + DSI_SIZE + 3] != b"ACC":
        raise ValueError(f"DTED: {path.name} has no ACC record after the DSI")

    uhl = buf[:UHL_SIZE]
    lon0 = _angle(uhl[4:12], "longitude origin", "E", "W")
    lat0 = _angle(uhl[12:20], "latitude origin", "N", "S")
    dlon_t = _int(uhl[20:24], "longitude interval")
    dlat_t = _int(uhl[24:28], "latitude interval")
    nlon = _int(uhl[47:51], "longitude line count")
    nlat = _int(uhl[51:55], "latitude point count")
    if dlon_t <= 0 or dlat_t <= 0 or nlon < 2 or nlat < 2:
        raise ValueError(f"DTED: {path.name} has an invalid grid ({nlon}x{nlat} posts, intervals {dlon_t}/{dlat_t})")

    rec_size = RECORD_PREFIX + 2 * nlat + RECORD_SUFFIX
    expected = HEADER_SIZE + nlon * rec_size
    if len(buf) != expected:
        kind = "truncated" if len(buf) < expected else "has trailing data"
        raise ValueError(f"DTED: {path.name} {kind}: {len(buf)} bytes, expected {expected} for {nlon}x{nlat} posts")

    dsi = buf[UHL_SIZE:UHL_SIZE + DSI_SIZE]
    series = _ascii(dsi[59:64]).upper()
    if series in ("DTED0", "DTED1", "DTED2"):
        level = series
    else:  # fall back to the latitude interval: 30" / 3" / 1"
        arcsec = dlat_t / 10.0
        level = "DTED0" if arcsec >= 10.0 else "DTED1" if arcsec >= 2.0 else "DTED2"

    rec = np.frombuffer(buf, dtype=np.uint8, offset=HEADER_SIZE).reshape(nlon, rec_size)
    bad = np.flatnonzero(rec[:, 0] != SENTINEL)
    if bad.size:
        raise ValueError(f"DTED: {path.name} data record {int(bad[0])} has sentinel {int(rec[bad[0], 0]):#04x}, "
                         f"expected {SENTINEL:#04x}")

    errors = 0
    if verify_checksums:
        sums = rec[:, :-RECORD_SUFFIX].sum(axis=1, dtype=np.uint64)
        stored = np.ascontiguousarray(rec[:, -RECORD_SUFFIX:]).view(">u4")[:, 0].astype(np.uint64)
        errors = int(np.count_nonzero(sums != stored))
        if errors:
            warnings.warn(f"DTED: {path.name}: {errors} of {nlon} data records have a bad checksum", stacklevel=2)

    raw = np.ascontiguousarray(rec[:, RECORD_PREFIX:RECORD_PREFIX + 2 * nlat]).view(">u2").astype(np.uint16)
    mag = (raw & 0x7FFF).astype(np.float32)
    elev = np.where(raw & 0x8000, -mag, mag)
    elev[(raw == VOID_RAW[0]) | (raw == VOID_RAW[1])] = np.nan
    data = np.ascontiguousarray(elev.T[::-1])  # (nlon, nlat) south->north  ->  (nlat, nlon) north->south

    return DtedCell(
        path=path, level=level, lat0=lat0, lon0=lon0, dlat=dlat_t / ARCSEC_TENTHS_PER_DEG,
        dlon=dlon_t / ARCSEC_TENTHS_PER_DEG, data=data, vertical_datum=_ascii(dsi[141:144]),
        horizontal_datum=_ascii(dsi[144:149]), checksum_errors=errors)
