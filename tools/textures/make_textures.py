#!/usr/bin/env python3
"""
make_textures.py - generates the detailed surface textures for the Godot version of Lost City.

    python3 tools/textures/make_textures.py

Everything is drawn from fixed random seeds with numpy, so no downloaded images (and no licences)
are involved and the output is the same on every run. Every texture tiles seamlessly: the noise is
made in the frequency domain (FFT), and shapes that cross an edge wrap around to the other side.

Output goes to godot/assets/pbr/:
    drops_n.png          rain beads on car paint and glass (normal map, 256 px = 25 cm)
    asphalt_a.png        street surface colour (1024 px = 2.5 m)
    asphalt_n.png        street detail: normal x/y (red, green), roughness (blue), height (alpha)
    paving_a.png         sidewalk slabs colour (1024 px = 3 m, 1.5 m slabs)
    paving_n.png         sidewalk detail, packed like asphalt_n
    brick_n.png          relief for the brick photo (godot/assets/brick.jpg): normal x/y, cavity
    wall_streaks.png     how wet each part of a wall is (rain running down)
"""
import os
import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'godot', 'assets', 'pbr')


# ---------------------------------------------------------------- helpers
def fbm(n, seed, beta=2.0, lo=1.0, hi=None):
    """Tileable fractal noise: white noise shaped to a 1/f^beta spectrum, band-limited to lo..hi cycles
    per tile. Returned normalised to mean 0, std 1."""
    rng = np.random.default_rng(seed)
    fx = np.fft.fftfreq(n) * n
    f = np.sqrt(fx[None, :] ** 2 + fx[:, None] ** 2)
    hi = hi or n / 2
    amp = np.where((f >= lo) & (f <= hi), 1.0 / np.maximum(f, 1e-6) ** (beta / 2.0), 0.0)
    ph = np.fft.fft2(rng.standard_normal((n, n)))
    v = np.real(np.fft.ifft2(ph * amp))
    return (v - v.mean()) / (v.std() + 1e-9)


def norm01(v):
    return (v - v.min()) / (v.max() - v.min() + 1e-9)


def normal_map(h, strength):
    """Tangent-space normal map (OpenGL convention, +Y up, as Godot expects) from a tileable height map."""
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5 * strength
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5 * strength
    nx, ny, nz = -dx, dy, np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack([nx / ln, ny / ln, nz / ln], -1) * 0.5 + 0.5


def voronoi(n, cells, seed, jitter=0.9):
    """Tileable cellular noise on an n x n image with cells x cells jittered points.
    Returns (F1, F2) distances in pixels and the id of the nearest cell."""
    rng = np.random.default_rng(seed)
    c = n / cells
    pts = np.stack([(np.arange(cells)[None, :] + 0.5 + (rng.random((cells, cells)) - 0.5) * jitter) * c,
                    (np.arange(cells)[:, None] + 0.5 + (rng.random((cells, cells)) - 0.5) * jitter) * c], -1)
    yy, xx = np.mgrid[0:n, 0:n] + 0.5
    cx = (xx // c).astype(int)
    cy = (yy // c).astype(int)
    f1 = np.full((n, n), 1e9)
    f2 = np.full((n, n), 1e9)
    ids = np.zeros((n, n), int)
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            gx = cx + ox
            gy = cy + oy
            p = pts[gy % cells, gx % cells]
            px = p[..., 0] + (gx - gx % cells) * c
            py = p[..., 1] + (gy - gy % cells) * c
            d = np.sqrt((xx - px) ** 2 + (yy - py) ** 2)
            cid = (gy % cells) * cells + gx % cells
            closer = d < f1
            f2 = np.where(closer, f1, np.minimum(f2, d))
            ids = np.where(closer, cid, ids)
            f1 = np.where(closer, d, f1)
    return f1, f2, ids


def blur(v, r):
    """Tileable box-ish blur (three passes of a moving average, close to a gaussian)."""
    for _ in range(3):
        for ax in (0, 1):
            acc = np.zeros_like(v)
            for k in range(-r, r + 1):
                acc += np.roll(v, k, ax)
            v = acc / (2 * r + 1)
    return v


def save(name, arr):
    arr = np.clip(arr, 0.0, 1.0)
    img = Image.fromarray((arr * 255.0 + 0.5).astype(np.uint8))
    img.save(os.path.join(OUT, name), optimize=True)
    print('%-20s %dx%d' % (name, img.width, img.height))


def stamp(canvas, cx, cy, patch):
    """Adds patch into canvas centred on (cx, cy), wrapping around the edges (max keeps overlaps round)."""
    n = canvas.shape[0]
    ph, pw = patch.shape
    ys = (np.arange(ph) + int(cy) - ph // 2) % n
    xs = (np.arange(pw) + int(cx) - pw // 2) % n
    sub = canvas[np.ix_(ys, xs)]
    canvas[np.ix_(ys, xs)] = np.maximum(sub, patch)


# ---------------------------------------------------------------- rain beads
def drops():
    n = 256
    rng = np.random.default_rng(11)
    h = np.zeros((n, n))
    # many tiny beads, fewer big ones; each is a spherical cap
    for count, rmin, rmax in ((900, 0.8, 2.2), (260, 2.2, 4.5), (40, 4.5, 7.5)):
        for _ in range(count):
            r = rng.uniform(rmin, rmax)
            k = int(np.ceil(r)) + 1
            yy, xx = np.mgrid[-k:k + 1, -k:k + 1]
            # slightly squashed, like beads on a slope
            d2 = (xx / r) ** 2 + (yy / (r * rng.uniform(0.8, 1.15))) ** 2
            cap = np.sqrt(np.clip(1.0 - d2, 0.0, 1.0)) * r
            stamp(h, rng.uniform(0, n), rng.uniform(0, n), cap)
    save('drops_n.png', normal_map(h, 0.9))


def pack_nrh(nrm, rough, height):
    """Detail map: normal x and y in red and green, roughness in blue, height in alpha."""
    return np.dstack([nrm[..., 0], nrm[..., 1], rough, height])


# ---------------------------------------------------------------- asphalt (1024 px = 2.5 m)
def asphalt():
    n = 1024
    rng = np.random.default_rng(21)
    # aggregate (about 6-12 mm) packed in dark binder; only the tops of some stones show through
    f1, f2, cid = voronoi(n, 250, 1)
    tone = rng.random(250 * 250)[cid]
    wear = norm01(fbm(n, 3, beta=2.4, lo=1, hi=10))            # worn areas expose more stone
    cell = n / 250
    dome = np.sqrt(np.clip(1 - (f1 / (0.62 * cell)) ** 2, 0, 1))
    expose = np.clip((f2 - f1 - 0.9) / 1.2, 0, 1) * np.clip((tone - 0.62 + 0.35 * wear) / 0.12, 0, 1)
    grain = fbm(n, 4, beta=0.4, lo=60)                          # sand and fines in the binder
    mott = fbm(n, 5, beta=2.2, lo=2, hi=40)
    binder = 0.042 + 0.006 * grain + 0.006 * mott
    rock = 0.07 + 0.2 * rng.random(250 * 250)[cid] ** 2.5
    alb = binder * (1 - expose) + rock * expose
    h = 0.4 + 0.03 * grain + 0.02 * mott + expose * (0.12 + 0.25 * dome) - 0.12 * (1 - dome) * (tone > 0.5)
    rough = 0.9 - 0.25 * expose * tone + 0.03 * grain
    # cracks: wandering lines where the surface has split; water runs into them
    crack = np.zeros((n, n))
    for _ in range(7):
        x, y = rng.uniform(0, n, 2)
        a = rng.uniform(0, 2 * np.pi)
        w = rng.uniform(0.7, 1.4)
        for _ in range(int(rng.uniform(120, 380))):
            a += rng.normal(0, 0.3)
            x = (x + np.cos(a) * 1.5) % n
            y = (y + np.sin(a) * 1.5) % n
            crack[int(y), int(x)] = max(crack[int(y), int(x)], w)
            if rng.random() < 0.02:   # small branch
                bx, by, ba = x, y, a + rng.choice([-1, 1]) * rng.uniform(0.6, 1.3)
                for _ in range(int(rng.uniform(10, 50))):
                    ba += rng.normal(0, 0.4)
                    bx = (bx + np.cos(ba) * 1.5) % n
                    by = (by + np.sin(ba) * 1.5) % n
                    crack[int(by), int(bx)] = max(crack[int(by), int(bx)], w * 0.6)
    crack = np.clip(blur(crack, 1) * 3.5, 0, 1)
    alb = alb * (1 - 0.5 * crack)
    h = h - 0.4 * crack
    rough = rough + 0.05 * crack
    # oil drips and tyre polish: darker, smoother patches
    oil = np.clip(fbm(n, 6, beta=3.0, lo=2, hi=24) - 1.4, 0, 1)
    alb = alb * (1 - 0.3 * oil)
    rough = rough - 0.35 * oil
    h = norm01(h)
    save('asphalt_a.png', np.dstack([alb, alb, alb * 1.05]) ** (1 / 2.2))
    save('asphalt_n.png', pack_nrh(normal_map(h, 5.0), np.clip(rough, 0.05, 1), h))


# ---------------------------------------------------------------- sidewalk paving (1024 px = 3 m, 1.5 m slabs)
def paving():
    n = 1024
    k = 2                       # slabs per side
    sz = n // k
    rng = np.random.default_rng(31)
    yy, xx = np.mgrid[0:n, 0:n] + 0.5
    lx = xx % sz
    ly = yy % sz
    sid = (yy // sz).astype(int) * k + (xx // sz).astype(int)
    edge = np.minimum(np.minimum(lx, sz - lx), np.minimum(ly, sz - ly))   # px to the nearest joint
    joint = np.clip(1.0 - (edge - 1.2) / 1.2, 0, 1)
    bevel = np.clip((edge - 1.5) / 5.0, 0, 1)
    # each slab sits a little crooked and has its own shade
    tilt = rng.normal(0, 1, (k * k, 2)) * 0.05
    tone = 1.0 + rng.normal(0, 0.07, k * k)
    plane = (tilt[sid, 0] * (lx / sz - 0.5) + tilt[sid, 1] * (ly / sz - 0.5))
    mott = fbm(n, 32, beta=2.0, lo=2, hi=60)
    fine = fbm(n, 33, beta=0.3, lo=80)
    alb = 0.105 * tone[sid] * (1 + 0.08 * mott + 0.05 * fine)
    h = 0.62 + plane + 0.02 * mott + 0.015 * fine
    rough = 0.84 + 0.04 * fine
    # pits (air holes in the concrete)
    pits = np.zeros((n, n))
    for _ in range(1400):
        r = rng.uniform(0.6, 1.6)
        q = int(np.ceil(r)) + 1
        oy, ox = np.mgrid[-q:q + 1, -q:q + 1]
        stamp(pits, rng.uniform(0, n), rng.uniform(0, n), np.clip(1 - (ox * ox + oy * oy) / (r * r), 0, 1))
    alb *= 1 - 0.35 * pits
    h -= 0.06 * pits
    # stains, old gum and drips: darker and a bit smoother
    stain = np.clip(fbm(n, 34, beta=2.8, lo=2, hi=30) - 1.0, 0, 1.5)
    gum = np.zeros((n, n))
    for _ in range(26):
        r = rng.uniform(2.5, 6.0)
        q = int(np.ceil(r)) + 2
        oy, ox = np.mgrid[-q:q + 1, -q:q + 1]
        stamp(gum, rng.uniform(0, n), rng.uniform(0, n), np.clip((1 - np.sqrt(ox * ox + oy * oy) / r) * 3, 0, 1))
    alb *= (1 - 0.25 * stain) * (1 - 0.45 * gum)
    rough -= 0.2 * np.clip(stain, 0, 1) + 0.25 * gum
    h += 0.015 * gum
    # a hairline crack across one slab
    crack = np.zeros((n, n))
    x, y = rng.uniform(40, sz - 40), 0.0
    a = np.pi / 2 + rng.normal(0, 0.3)
    while 0 <= y < sz and 0 <= x < sz:
        a += rng.normal(0, 0.25)
        a = np.clip(a, 0.6, 2.5)
        x += np.cos(a) * 1.2
        y += np.sin(a) * 1.2
        crack[int(y) % n, int(x) % n] = 1
    crack = np.clip(blur(crack, 1) * 3.0, 0, 1)
    alb *= 1 - 0.5 * crack
    h -= 0.25 * crack
    # the joints: dark grooves with rounded edges, dirt collects in them
    alb = alb * (1 - 0.55 * joint) * (0.93 + 0.07 * bevel)
    h = h - 0.35 * joint - 0.06 * (1 - bevel)
    rough = rough + 0.05 * joint
    h = norm01(h)
    save('paving_a.png', np.dstack([alb * 1.02, alb, alb * 0.97]) ** (1 / 2.2))
    save('paving_n.png', pack_nrh(normal_map(h, 4.0), np.clip(rough, 0.05, 1), h))


# ---------------------------------------------------------------- brick relief (from godot/assets/brick.jpg)
def brick_relief():
    """Relief for the brick photo the walls already use: the orange bricks stand out, the grey mortar
    (low colour saturation) sits back. Normal x/y in red/green, cavity (dark in the joints) in blue."""
    src = os.path.join(OUT, '..', 'brick.jpg')
    b = np.asarray(Image.open(src).convert('RGB')).astype(float) / 255.0
    mx = b.max(-1)
    sat = (mx - b.min(-1)) / (mx + 1e-6)
    brick = np.clip((sat - 0.24) / 0.2, 0, 1)
    brick = blur(brick, 1)
    face = blur(b.mean(-1), 1) - blur(b.mean(-1), 6)          # small dents and chips on the faces
    h = 0.55 * brick + 0.8 * face * brick
    cav = 0.55 + 0.45 * blur(brick, 2)
    save('brick_n.png', np.dstack([normal_map(h, 3.0)[..., 0], normal_map(h, 3.0)[..., 1], cav]))


# ---------------------------------------------------------------- rain streaks on walls (256 px, stretched tall)
def wall_streaks():
    """Grey level = how wet the wall is: long vertical runs of water below ledges, blotchy damp patches."""
    n = 256
    rng = np.random.default_rng(41)
    fx = np.fft.fftfreq(n) * n
    kx, ky = np.meshgrid(fx, fx)
    # anisotropic spectrum: fine across, long up and down
    f = np.sqrt((kx * 1.0) ** 2 + (ky * 7.0) ** 2)
    amp = np.where(f > 0, 1.0 / np.maximum(f, 1e-6) ** 1.3, 0)
    v = np.real(np.fft.ifft2(np.fft.fft2(rng.standard_normal((n, n))) * amp))
    v = (v - v.mean()) / v.std()
    damp = fbm(n, 42, beta=2.4, lo=1, hi=16)
    w = np.clip(0.45 + 0.28 * v + 0.15 * damp, 0, 1)
    save('wall_streaks.png', w)


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    drops()
    asphalt()
    paving()
    brick_relief()
    wall_streaks()
