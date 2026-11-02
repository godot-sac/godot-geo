"""Generate the close-range detail textures used by the godot-geo terrain shader.

Both PNG atlases are generated here from nothing but numpy noise and Pillow
drawing of our own; no third-party texture, photo or noise code is used (MIT,
same licence as the rest of the add-on). The script is deterministic: every
slice has a fixed seed, so re-running it reproduces the files bit for bit.

Output (8 slices of 512 x 512 side by side, 4096 x 512 each):

    addons/geo/textures/detail_albedo.png   RGB8, every channel of every slice
                                            has a mean of 128 (0.5)
    addons/geo/textures/detail_normal.png   RGB8 tangent-space normal map,
                                            OpenGL convention (green = +Y up)

The shader computes ``satellite * 2.0 * detail``: colour comes from the
satellite image, the detail only adds high-frequency structure and keeps the
average colour unchanged because its mean is 0.5.

Slice order and the real-world size one slice spans (the shader tiles with
these sizes):

    0 forest floor        4 m     leaf litter, twigs, dark soil
    1 shrub / dry grass   4 m     tufts, bare patches
    2 grassland           3 m     fine blades, clover, mown feel
    3 cropland            8 m     tilled soil, furrows (vertical), clods
    4 built-up ground     6 m     asphalt with cracks, cobbles, paving stones
    5 bare ground / rock  4 m     pebbles, stones, cracked earth
    6 snow                8 m     soft drifts, very subtle
    7 wetland             6 m     mud with smooth puddle patches

Usage (repo root):
    tools/.venv/Scripts/python.exe -I tools/make_detail_textures.py [--preview PNG]
"""

import argparse
import pathlib

import numpy as np
from PIL import Image

N = 512
STEP = 4  # level spacing of the 8-bit output (see quantise)
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "addons" / "geo" / "textures"


# --------------------------------------------------------------- primitives

def std1(a):
    """Zero mean, unit standard deviation."""
    a = a - a.mean()
    s = a.std()
    return a / s if s > 0 else a


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def fft_noise(rng, lo, hi, slope=1.0, stretch_x=1.0):
    """Periodic noise: white noise filtered in Fourier space.

    lo / hi are band limits in cycles per tile, slope the amplitude falloff
    (1 = pink-ish, 2 = very smooth). stretch_x > 1 elongates features along x.
    """
    fx = np.fft.fftfreq(N) * N
    f = np.hypot(fx[None, :] * stretch_x, fx[:, None])
    f[0, 0] = 1.0
    amp = f ** -slope / (1 + (lo / f) ** 4) / (1 + (f / hi) ** 4)
    amp[0, 0] = 0.0
    spec = np.fft.fft2(rng.standard_normal((N, N))) * amp
    return std1(np.fft.ifft2(spec).real)


def blur(a, sigma):
    fr = np.fft.fftfreq(N)
    k = np.exp(-2 * np.pi ** 2 * sigma ** 2 * (fr[None, :] ** 2 + fr[:, None] ** 2))
    return np.fft.ifft2(np.fft.fft2(a) * k).real


def shade(h, sigma):
    """Cavity shading: height relative to its blurred surroundings."""
    return std1(h - blur(h, sigma))


def worley(rng, cells, jitter=1.0, warp=None):
    """Wrapped cellular noise: (F1, F2, per-cell random values of the nearest cell).

    Distances are in cell units. warp = (dx, dy) in cell units distorts the lookup.
    """
    pts = rng.random((cells, cells, 2))
    rnd = rng.random((cells, cells, 4))
    g = (np.arange(N) + 0.5) / N * cells
    x, y = np.meshgrid(g, g)
    if warp is not None:
        x = x + warp[0]
        y = y + warp[1]
    ci = np.floor(x).astype(int)
    cj = np.floor(y).astype(int)
    f1 = np.full((N, N), np.inf)
    f2 = np.full((N, N), np.inf)
    ni = np.zeros((N, N), int)
    nj = np.zeros((N, N), int)
    for dj in (-1, 0, 1):
        for di in (-1, 0, 1):
            a = ci + di
            b = cj + dj
            px = a + 0.5 + (pts[b % cells, a % cells, 0] - 0.5) * jitter
            py = b + 0.5 + (pts[b % cells, a % cells, 1] - 0.5) * jitter
            d = np.hypot(x - px, y - py)
            closer = d < f1
            f2 = np.where(closer, f1, np.minimum(f2, d))
            ni = np.where(closer, a % cells, ni)
            nj = np.where(closer, b % cells, nj)
            f1 = np.where(closer, d, f1)
    return f1, f2, rnd[nj, ni]


def sample(field, x, y):
    return field[np.floor(y).astype(int) % N, np.floor(x).astype(int) % N]


class Canvas:
    """Painter's canvas for strokes: height plus K payload channels per pixel.

    Strokes are drawn in order of height, so higher ones cover lower ones.
    Empty pixels keep height -1. Everything wraps at the tile border.
    """

    def __init__(self, k=2):
        self.h = np.full((N, N), -1.0)
        self.c = np.zeros((N, N, k))

    def put(self, px, py, h, pay):
        flat = (np.rint(py).astype(np.int64) % N) * N + np.rint(px).astype(np.int64) % N
        hv = self.h.reshape(-1)
        keep = h > hv[flat]
        flat, h, pay = flat[keep], h[keep], pay[keep]
        order = np.argsort(h, kind="stable")
        hv[flat[order]] = h[order]
        self.c.reshape(-1, self.c.shape[-1])[flat[order]] = pay[order]

    def strokes(self, x, y, ang, length, halfw, h0, h1, pay, taper=0.0, bend=0.0,
                hump=0.0, ridge=0.0, lens=0.0, cross=3):
        """Draw n strokes. Per-stroke arguments may be arrays or scalars.

        Height runs linearly h0 -> h1 along the stroke, plus a sqrt-sine hump
        (leaves) and a cross-section ridge. taper narrows towards the tip,
        lens narrows both ends, bend curves the stroke sideways.
        """
        n = len(x)

        def v(a):
            return np.broadcast_to(np.asarray(a, float), (n,))[:, None, None]

        x, y, ang, length, halfw = v(x), v(y), v(ang), v(length), v(halfw)
        h0, h1, bend, hump = v(h0), v(h1), v(bend), v(hump)
        steps = int(np.max(length) * 1.5) + 2
        t = np.linspace(0, 1, steps)[None, :, None]
        o = np.linspace(-1, 1, cross)[None, None, :]
        width = halfw * (1 - taper * t) * np.sin(np.pi * t) ** lens
        side = o * width + bend * length * t * t
        dx, dy = np.cos(ang), np.sin(ang)
        px = x + dx * length * t - dy * side
        py = y + dy * length * t + dx * side
        h = h0 + (h1 - h0) * t + hump * np.sqrt(np.sin(np.pi * t)) * (1 - o ** 2) \
            + ridge * (1 - o ** 2)
        shape = px.shape
        pay = np.broadcast_to(np.asarray(pay, float).reshape(n, 1, 1, -1), shape + (self.c.shape[-1],))
        self.put(px.reshape(-1), py.reshape(-1), np.broadcast_to(h, shape).reshape(-1),
                 pay.reshape(-1, self.c.shape[-1]))

    def fill(self, base_h, base_c):
        empty = self.h < 0
        return np.where(empty, base_h, self.h), np.where(empty[..., None], base_c, self.c)


def dome(f1, radius):
    """Round stone profile: 1 in the middle, 0 at the radius."""
    return np.clip(1 - (f1 / radius) ** 2, 0, 1) ** 0.5


# ------------------------------------------------------------------ slices
# Every slice returns (height, luminance field, warmth field). Height drives
# the normal map and cavity shading; warmth is a hue axis (+ = browner/yellower).

def forest(rng):
    soil = 0.1 + 0.03 * fft_noise(rng, 4, 150, 1.0)
    patch = fft_noise(rng, 1.5, 5, 1.0)
    cv = Canvas()

    n = 15000
    x, y = rng.random(n) * N, rng.random(n) * N
    keep = rng.random(n) > 0.96 * smoothstep(0.2, 1.3, sample(patch, x, y))
    x, y = x[keep], y[keep]
    n = len(x)
    length = rng.uniform(7, 14, n)
    h0 = rng.uniform(0.3, 0.9, n)
    tone = rng.normal(0, 1, n) - 0.8 * (h0 - 0.6) / 0.17
    warm = rng.normal(0.4, 1, n)
    cv.strokes(x, y, rng.uniform(0, 2 * np.pi, n), length, length * rng.uniform(0.17, 0.27, n),
               h0, h0 + rng.normal(0, 0.05, n), np.stack([tone, warm], 1),
               hump=0.1, lens=0.5, cross=7)

    n = 7000  # crumbs of bark and litter
    x, y = rng.random(n) * N, rng.random(n) * N
    cv.strokes(x, y, rng.uniform(0, 2 * np.pi, n), rng.uniform(2, 5, n), 0.8,
               rng.uniform(0.4, 0.7, n), 0.7, np.stack([rng.normal(-0.2, 0.8, n), rng.normal(0, 1, n)], 1),
               hump=0.05, lens=0.5, cross=3)

    for count, lo, hi in ((45, 30, 150), (220, 8, 26)):  # twigs
        x, y = rng.random(count) * N, rng.random(count) * N
        cv.strokes(x, y, rng.uniform(0, 2 * np.pi, count), rng.uniform(lo, hi, count), 0.7,
                   1.2, 1.2, np.stack([np.full(count, -1.1), np.full(count, 0.6)], 1),
                   bend=rng.normal(0, 0.1, count), ridge=0.06, cross=3)

    soil_tone = -1.0 + 0.5 * fft_noise(rng, 8, 250, 0.7) - 0.7 * smoothstep(0.3, 1.3, patch)
    h, c = cv.fill(soil, np.stack([soil_tone, np.zeros((N, N))], -1))
    lum = 0.8 * std1(c[..., 0]) + 0.9 * shade(h, 2.0)
    return h, lum, c[..., 1]


def shrub(rng):
    bare = fft_noise(rng, 1.5, 5, 1.0)
    bare_w = smoothstep(0.3, 0.7, bare)
    soil = 0.05 + 0.02 * fft_noise(rng, 6, 200, 0.8)
    cv = Canvas()

    # tufts: blades spreading from a raised centre
    tufts = 190
    cx, cy = rng.random(tufts) * N, rng.random(tufts) * N
    keep = rng.random(tufts) > smoothstep(0.1, 0.8, sample(bare, cx, cy))
    cx, cy = cx[keep], cy[keep]
    tufts = len(cx)
    per = 60
    idx = np.repeat(np.arange(tufts), per)
    m = len(idx)
    size = rng.uniform(0.7, 1.3, tufts)[idx]
    length = rng.uniform(10, 30, m) * size
    lean = rng.uniform(0, 2 * np.pi, tufts)[idx]  # tufts lean to one side and are not round
    ang = lean + rng.normal(0, 1.6, m) + rng.uniform(-1, 1, m) * 1.2
    r0 = rng.uniform(0, 5, m)
    tuft_tone = rng.normal(0, 0.5, tufts)[idx]
    tuft_warm = rng.normal(0.4, 0.7, tufts)[idx]
    hc = 0.8 - 0.3 * length / 40
    cv.strokes(cx[idx] + np.cos(ang) * r0, cy[idx] + np.sin(ang) * r0, ang, length, 0.8,
               hc, 0.12 + rng.uniform(0, 0.1, m),
               np.stack([tuft_tone + rng.normal(0, 0.9, m), tuft_warm + rng.normal(0, 0.5, m)], 1),
               taper=0.8, bend=rng.normal(0, 0.35, m), ridge=0.03, cross=3)

    # loose dry stalks between the tufts
    n = 3500
    x, y = rng.random(n) * N, rng.random(n) * N
    keep = rng.random(n) > 0.6 * bare_w[y.astype(int), x.astype(int)]
    x, y = x[keep], y[keep]
    n = len(x)
    cv.strokes(x, y, rng.uniform(0, 2 * np.pi, n), rng.uniform(6, 16, n), 0.7,
               rng.uniform(0.15, 0.3, n), rng.uniform(0.2, 0.4, n),
               np.stack([rng.normal(0.3, 1, n), rng.normal(0.6, 0.6, n)], 1),
               taper=0.7, bend=rng.normal(0, 0.2, n), cross=3)

    # bare earth between: fine grain, a few pebbles
    f1, _, r = worley(rng, 85)
    pebbles = dome(f1, 0.15 + 0.2 * r[..., 1]) * (r[..., 0] < 0.25)
    soil_h = soil + 0.12 * pebbles
    soil_tone = 0.3 * bare_w + 0.5 * fft_noise(rng, 20, 250, 0.5) + 1.2 * pebbles * (r[..., 2] - 0.5)
    soil_warm = 0.3 * fft_noise(rng, 2, 8, 1.0)
    h, c = cv.fill(soil_h, np.stack([soil_tone - 0.6, soil_warm], -1))
    lum = 0.8 * std1(c[..., 0]) + 0.9 * shade(h, 2.0)
    return h, lum, c[..., 1]


def grass(rng):
    cv = Canvas()
    flow = fft_noise(rng, 1.5, 5, 1.0)
    patch = fft_noise(rng, 2, 8, 1.0)
    warm_f = fft_noise(rng, 2, 10, 1.0)

    # clover patches: low rounded leaves, grass thinned out inside
    pc = 40
    px, py = rng.random(pc) * N, rng.random(pc) * N
    pr = rng.uniform(12, 24, pc)

    def wrapped_dist(x, y):
        dx = np.abs(x[:, None] - px[None, :])
        dy = np.abs(y[:, None] - py[None, :])
        dx, dy = np.minimum(dx, N - dx), np.minimum(dy, N - dy)
        return np.hypot(dx, dy) / pr[None, :]

    n = 60000
    x, y = rng.random(n) * N, rng.random(n) * N
    inside = (wrapped_dist(x, y) < 1).any(axis=1)
    keep = ~inside | (rng.random(n) > 0.9)
    x, y = x[keep], y[keep]
    n = len(x)
    ang = 1.3 * sample(flow, x, y) + rng.normal(0, 0.9, n)
    pf = sample(patch, x, y)
    cv.strokes(x, y, ang, rng.uniform(4, 9, n), 0.6, rng.uniform(0, 0.45, n),
               rng.uniform(0.5, 0.95, n),
               np.stack([rng.normal(0, 1, n) + 0.5 * pf, rng.normal(0, 0.8, n) + 0.6 * sample(warm_f, x, y)], 1),
               taper=0.7, bend=rng.normal(0, 0.3, n), ridge=0.05, cross=3)

    # clover: clusters of three-lobed leaves
    for k in range(pc):
        m = 60
        a = rng.uniform(0, 2 * np.pi, m)
        rad = pr[k] * np.sqrt(rng.random(m))
        lx, ly = px[k] + np.cos(a) * rad, py[k] + np.sin(a) * rad
        base = rng.uniform(0.2, 0.5, m)
        for lobe in range(3):
            ang = rng.uniform(0, 2 * np.pi, m) + lobe * 2.094
            cv.strokes(lx, ly, ang, rng.uniform(5, 8, m), 2.2, base + 0.55, base + 0.55,
                       np.stack([rng.normal(0.4, 0.9, m), np.full(m, -1.4) + rng.normal(0, 0.4, m)], 1),
                       hump=0.15, lens=0.5, cross=5)

    gap_tone = -1.7 + 0.3 * fft_noise(rng, 20, 250, 0.5)
    h, c = cv.fill(np.zeros((N, N)), np.stack([gap_tone, np.zeros((N, N))], -1))
    lum = 0.9 * std1(c[..., 0]) + 0.7 * shade(h, 1.5)
    return h, lum, c[..., 1]


def crop(rng):
    u = (np.arange(N) + 0.5) / N
    xx, yy = np.meshgrid(u, u)
    # 12 furrows across the tile; low-frequency warp wobbles them, the tile still wraps
    phase = 12 * xx + 0.12 * fft_noise(rng, 1, 4, 1.5)
    amp = 0.85 + 0.15 * smoothstep(-1.5, 1.5, fft_noise(rng, 1, 5, 1.0))
    ridge = (0.5 + 0.5 * np.cos(2 * np.pi * phase)) ** 1.3 * amp

    f1, _, r = worley(rng, 90)
    # clods sit mostly on the ridges
    present = r[..., 0] < 0.25 + 0.5 * ridge
    clods = dome(f1, (0.25 + 0.25 * r[..., 1]) * (1 + 0.25 * fft_noise(rng, 30, 120, 0.5))) * present
    lumps = fft_noise(rng, 8, 120, 1.3)
    h = 1.0 * ridge + 0.25 * clods + 0.05 * lumps

    dry = fft_noise(rng, 2, 7, 1.0)
    tone = (0.9 * (ridge - 0.5) / 0.3 + 0.5 * clods * (r[..., 2] - 0.5) * 2
            + 0.6 * fft_noise(rng, 20, 250, 0.6) + 0.5 * fft_noise(rng, 4, 20, 1.0))
    lum = 0.8 * std1(tone) + 0.8 * shade(h, 3.0)
    return h, lum, 0.7 * dry + 0.5 * (r[..., 3] - 0.5) * clods


def brick_layer(rng, cols, rows):
    """Running-bond pavers: (height, tone, warmth)."""
    table = rng.random((rows, cols, 3))
    g = (np.arange(N) + 0.5) / N
    xx, yy = np.meshgrid(g, g)
    u, v = xx * cols, yy * rows
    row = np.floor(v).astype(int)
    u2 = u + 0.5 * (row % 2)
    col = np.floor(u2).astype(int) % cols
    fu, fv = u2 - np.floor(u2), v - row
    px_w, px_h = N / cols, N / rows
    d = np.minimum(np.minimum(fu, 1 - fu) * px_w, np.minimum(fv, 1 - fv) * px_h)
    t = table[row % rows, col]
    top = smoothstep(0.7, 2.4, d)
    h = 0.15 * (t[..., 0] - 0.5) + 0.85 * top
    tone = (t[..., 1] - 0.5) * 2.4 - 1.5 * (1 - top)
    return h, tone, (t[..., 2] - 0.5) * 2


def built(rng):
    reg = fft_noise(rng, 1.5, 5, 1.0)
    q1, q2 = np.quantile(reg, [0.5, 0.76])
    w_pave = smoothstep(q2 - 0.12, q2 + 0.12, reg)
    w_cob = smoothstep(q1 - 0.12, q1 + 0.12, reg) * (1 - w_pave)
    w_asp = 1 - w_cob - w_pave

    # asphalt: grain, aggregate, ageing patches, cracks
    grain = std1(blur(rng.standard_normal((N, N)), 0.6))
    f1, _, r = worley(rng, 170)
    stones = dome(f1, 0.25 + 0.2 * r[..., 1]) * (r[..., 0] < 0.5)
    ageing = fft_noise(rng, 2, 10, 1.2)
    cracks = np.zeros((N, N))
    for cells, width, density in ((7, 0.03, 0.9), (16, 0.02, 0.3)):
        warp = (0.25 * fft_noise(rng, 6, 30, 1.0), 0.25 * fft_noise(rng, 6, 30, 1.0))
        a, b, _ = worley(rng, cells, 1.0, warp)
        where = smoothstep(density - 0.5, density + 0.5, fft_noise(rng, 1.5, 4, 1.0))
        cracks = np.maximum(cracks, np.exp(-(((b - a) / width) ** 2)) * where)
    h_asp = 0.2 * grain + 0.35 * stones - 0.9 * cracks + 0.25
    tone_asp = 0.45 * grain + 0.6 * ageing + 1.6 * stones * (r[..., 2] - 0.5) - 2.5 * cracks
    warm_asp = 0.15 * ageing

    # cobbles: rounded stones with dark joints
    f1, f2, r = worley(rng, 30, 0.8)
    top = smoothstep(0.0, 0.35, f2 - f1) ** 0.7
    h_cob = 0.15 * (r[..., 0] - 0.5) + 0.85 * top + 0.04 * grain + 0.15
    tone_cob = (r[..., 2] - 0.5) * 2.2 - 1.5 * (1 - top) + 0.3 * grain
    warm_cob = (r[..., 3] - 0.5) * 2

    h_br, tone_br, warm_br = brick_layer(rng, 30, 60)
    h = w_asp * h_asp + w_cob * h_cob + w_pave * (h_br + 0.15)
    tone = w_asp * tone_asp + w_cob * tone_cob + w_pave * tone_br
    warm = w_asp * warm_asp + w_cob * warm_cob + w_pave * warm_br
    lum = 0.9 * std1(tone) + 0.6 * shade(h, 2.0)
    return h, lum, warm


def bare(rng):
    base = 0.05 * fft_noise(rng, 20, 200, 0.8)
    density = smoothstep(-0.6, 0.8, fft_noise(rng, 1.5, 4, 1.0))

    # cracked dry earth in some places
    region = smoothstep(-0.1, 0.4, fft_noise(rng, 1.5, 4, 1.0))
    warp = (0.2 * fft_noise(rng, 5, 25, 1.0), 0.2 * fft_noise(rng, 5, 25, 1.0))
    a, b, r = worley(rng, 14, 1.0, warp)
    plate = smoothstep(0.0, 0.5, b - a)
    crack = np.exp(-(((b - a) / 0.05) ** 2))
    h_earth = base + region * (0.1 * plate - 0.18 * crack + 0.05 * (r[..., 0] - 0.5))
    tone = 0.5 * fft_noise(rng, 3, 250, 0.7) - region * (1.8 * crack - 0.4 * (r[..., 1] - 0.5))
    warm = 0.5 * fft_noise(rng, 2, 8, 1.0)

    # pebbles and sparse larger stones
    rough = 0.15 * fft_noise(rng, 20, 90, 0.5)
    f1, _, r = worley(rng, 70)
    rad = (0.25 + 0.2 * r[..., 1]) * (1 + rough)
    pebbles = dome(f1, rad) * (r[..., 0] < 0.15 + 0.65 * density)
    h_peb = 0.14 * pebbles * (0.7 + 0.5 * r[..., 3])
    tone_peb = (r[..., 2] - 0.5) * 2.4 - 0.7 * (1 - pebbles)
    warm_peb = (r[..., 3] - 0.5) * 2

    f1, _, r = worley(rng, 16)
    rad = (0.2 + 0.2 * r[..., 1]) * (1 + 1.2 * rough)
    rocks = dome(f1, rad) * (r[..., 0] < 0.3)
    surface = fft_noise(rng, 15, 150, 0.9)
    h_rock = 0.5 * rocks ** 0.8 * (0.8 + 0.35 * r[..., 3]) + 0.025 * surface * (rocks > 0)
    tone_rock = (r[..., 2] - 0.5) * 2.0 + 0.4 * surface

    h = h_earth
    for layer_h, layer_t, layer_w, mask in ((h_peb, tone_peb, warm_peb, pebbles),
                                           (h_rock, tone_rock, warm_peb, rocks)):
        on = mask > 0.02
        higher = on & (base + layer_h > h)
        h = np.where(higher, base + layer_h, h)
        tone = np.where(higher, layer_t, tone)
        warm = np.where(higher, layer_w, warm)
    lum = 0.8 * std1(tone) + 0.9 * shade(h, 2.5)
    return h, lum, warm


def snow(rng):
    drifts = fft_noise(rng, 1.5, 8, 1.8)
    sastrugi = fft_noise(rng, 2, 14, 1.8, stretch_x=0.45)  # long ridges along x
    sparkle = std1(blur(rng.standard_normal((N, N)), 0.8))
    h = drifts + 0.6 * sastrugi + 0.05 * sparkle
    lum = 0.6 * shade(h, 6.0) + 0.5 * std1(h) + 0.25 * sparkle
    return h, lum, 0.3 * fft_noise(rng, 2, 6, 1.0)


def wetland(rng):
    pool = fft_noise(rng, 1.5, 4, 1.0)
    water = smoothstep(-0.4, -0.55, pool)  # roughly the lowest third of the tile
    water = smoothstep(0.0, 1.0, blur(water, 1.5))
    f1, _, r = worley(rng, 60)
    clods = dome(f1, 0.2 + 0.25 * r[..., 1]) * (r[..., 0] < 0.45)
    mud = 0.5 * fft_noise(rng, 3, 40, 1.4) + 0.25 * fft_noise(rng, 40, 250, 0.8) + 0.4 * clods

    cv = Canvas()
    tufts = 140
    cx, cy = rng.random(tufts) * N, rng.random(tufts) * N
    keep = sample(water, cx, cy) < 0.2
    cx, cy = cx[keep], cy[keep]
    tufts = len(cx)
    idx = np.repeat(np.arange(tufts), 18)
    m = len(idx)
    ang = rng.uniform(0, 2 * np.pi, m)
    cv.strokes(cx[idx], cy[idx], ang, rng.uniform(6, 14, m), 0.7, 0.5, 0.3,
               np.stack([rng.normal(-0.4, 0.9, m), rng.normal(-0.5, 0.6, m)], 1),
               taper=0.7, bend=rng.normal(0, 0.2, m), cross=3)

    level = 0.3 + 0.01 * fft_noise(rng, 20, 100, 1.0)  # puddle surface: almost flat
    ground = np.where(water > 0.5, level, level + 0.3 * mud * (1 - water))
    ground = level + (ground - level) * (1 - water) + 0.0 * water
    tone = 0.6 * std1(mud) - 1.6 * water + 0.3 * fft_noise(rng, 30, 250, 0.5) * (1 - water)
    h, c = cv.fill(ground, np.stack([tone, -0.5 * water + 0.3 * (1 - water)], -1))
    lum = 0.9 * std1(c[..., 0]) + 0.7 * shade(h, 3.0) * (1 - water)
    return h, lum, c[..., 1]


# (name, metres per slice, function, luminance std target, chroma, rms normal slope)
SLICES = [
    ("forest", 4.0, forest, 0.15, 0.035, 0.55),
    ("shrub", 4.0, shrub, 0.15, 0.035, 0.50),
    ("grass", 3.0, grass, 0.15, 0.03, 0.40),
    ("crop", 8.0, crop, 0.14, 0.025, 0.40),
    ("built", 6.0, built, 0.14, 0.02, 0.35),
    ("bare", 4.0, bare, 0.14, 0.03, 0.55),
    ("snow", 8.0, snow, 0.05, 0.015, 0.07),
    ("wetland", 6.0, wetland, 0.13, 0.03, 0.30),
]


# ---------------------------------------------------------------- assembly

def luma(rgb):
    return rgb @ np.array([0.2126, 0.7152, 0.0722])


def albedo_slice(lum, warm, lum_std, chroma):
    """Detail colour with mean 0.5 per channel and the requested luminance std."""
    lum = np.clip(std1(lum), -3.5, 3.5)
    warm = np.clip(std1(blur(warm, 1.5)), -3.0, 3.0)  # smooth hue keeps the PNG small
    tint = np.array([1.0, 0.1, -1.0]) * chroma
    factor = 1 + lum[..., None] * (2 * lum_std) + warm[..., None] * tint  # = 2 * detail
    rgb = np.clip(0.5 * factor, 0, 1)
    for _ in range(6):  # keep the mean at 0.5 even after clipping
        rgb = np.clip(rgb * (128 / 255) / rgb.reshape(-1, 3).mean(0), 0, 1)
    return rgb


def normal_slice(h, slope):
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) / 2
    gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) / 2  # per image row (down)
    k = slope / np.sqrt(np.mean(gx ** 2 + gy ** 2))
    n = np.stack([-gx * k, gy * k, np.ones_like(h)], -1)
    return n / np.linalg.norm(n, axis=-1, keepdims=True)


def quantise(v, step):
    """Round to multiples of step (128 is one): fewer levels, much smaller PNGs."""
    return np.clip(step * np.round(v / step), 0, 255).astype(np.uint8)


def build():
    albedo, normal, report = [], [], []
    for i, (name, size, fn, lum_std, chroma, slope) in enumerate(SLICES):
        rng = np.random.default_rng(1000 + i)
        h, lum, warm = fn(rng)
        a = quantise(albedo_slice(lum, warm, lum_std, chroma) * 255, STEP)
        n = (normal_slice(blur(h, 0.5), slope) * 0.5 + 0.5) * 255
        n[..., :2] = quantise(n[..., :2], 1 if name == "snow" else STEP)
        n = np.round(n).astype(np.uint8)
        albedo.append(a)
        normal.append(n)
        m = a.reshape(-1, 3).mean(0)
        s = luma(a / 255.0).std()
        nz = n[..., 2].mean()
        report.append(f"{i} {name:8s} {size:3.0f} m  mean RGB {m[0]:6.2f} {m[1]:6.2f} {m[2]:6.2f}"
                      f"  luma std {s:.3f}  normal.z mean {nz:6.1f}")
    return albedo, normal, report


def save_png(slices, path):
    img = Image.fromarray(np.concatenate(slices, axis=1), "RGB")
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True, compress_level=9)
    print(f"{path}  {path.stat().st_size / 1e6:.2f} MB")


def save_preview(albedo, normal, path):
    """Each slice tiled 2 x 2 above its normal map; plus a half-tile shifted
    albedo sheet, where any seam sits in the middle of the picture."""
    cell = 400
    cols = 4
    sheet = Image.new("RGB", (cols * cell, 4 * cell))
    for i, (a, n) in enumerate(zip(albedo, normal)):
        for row, tex in ((0, a), (1, n)):
            big = Image.fromarray(np.tile(tex, (2, 2, 1))).resize((cell, cell), Image.LANCZOS)
            sheet.paste(big, ((i % cols) * cell, ((i // cols) * 2 + row) * cell))
    sheet.save(path)
    seams = Image.new("RGB", (cols * N, 2 * N))
    for i, a in enumerate(albedo):
        shifted = np.roll(a, (N // 2, N // 2), (0, 1))
        seams.paste(Image.fromarray(shifted), ((i % cols) * N, (i // cols) * N))
    seams.save(path.with_name(path.stem + "_seams.png"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out-dir", type=pathlib.Path, default=OUT_DIR)
    ap.add_argument("--preview", type=pathlib.Path, help="write a tiling preview PNG (and *_seams.png)")
    args = ap.parse_args()
    albedo, normal, report = build()
    print("\n".join(report))
    save_png(albedo, args.out_dir / "detail_albedo.png")
    save_png(normal, args.out_dir / "detail_normal.png")
    if args.preview:
        save_preview(albedo, normal, args.preview)


if __name__ == "__main__":
    main()
