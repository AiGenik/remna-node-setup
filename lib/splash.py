#!/usr/bin/env python3
"""Procedural TrueColor ASCII East Asian portrait eye, living gaze & cosmos splash for remna-node-setup."""

import math
import os
import select
import shutil
import signal
import sys
import termios
import time
import tty


DEFAULT_DURATION = 6.5
DEMO_DURATION = 15.0
TARGET_FPS = 28.0
MIN_COLS = 50
MIN_ROWS = 18
RGB_STEP = 5

# Smooth velvety ASCII ramps without jagged letter clutter.
SKIN_RAMP = " .,:;-~=+"
SKIN_MAX = len(SKIN_RAMP) - 1
SKIN_CODES = [ord(ch) for ch in SKIN_RAMP]
SCLERA_RAMP = ".:-=+*#"
SCLERA_MAX = len(SCLERA_RAMP) - 1
SCLERA_CODES = [ord(ch) for ch in SCLERA_RAMP]
CORE_RAMP = " .,:;-~=+*oO0Q@#"
CORE_MAX = len(CORE_RAMP) - 1
CORE_CODES = [ord(ch) for ch in CORE_RAMP]

BAYER2X2 = ((0.0, 0.5), (0.75, 0.25))
SPACE_PACK = 32 << 24

CI_ENV_VARS = (
    "CI",
    "GITHUB_ACTIONS",
    "GITLAB_CI",
    "JENKINS_URL",
    "BUILDKITE",
    "CIRCLECI",
    "TRAVIS",
    "TF_BUILD",
)


class SplashSignal(BaseException):
    """Raised when SIGINT, SIGTERM, or SIGHUP interrupts the splash."""

    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def _truthy_env(name):
    value = os.environ.get(name, "")
    return value.strip().lower() in ("1", "yes", "true", "on")


def _in_ci():
    for var in CI_ENV_VARS:
        value = os.environ.get(var)
        if value is not None and value.strip().lower() not in ("", "0", "false", "no"):
            return True
    return False


def should_skip_splash():
    if _truthy_env("REMNA_NO_INTRO"):
        return True
    if os.environ.get("UI_NO_ANIMATION", "").strip().lower() == "yes":
        return True
    if os.environ.get("NO_COLOR") is not None:
        return True
    term = os.environ.get("TERM", "")
    if not term or term.strip().lower() == "dumb":
        return True
    if _in_ci():
        return True
    if not sys.stdout.isatty():
        return True
    return False


def _clamp(value, lo, hi):
    if value < lo:
        return lo
    if value > hi:
        return hi
    return value


def _smoothstep(edge0, edge1, x):
    t = (x - edge0) / (edge1 - edge0)
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0
    return t * t * (3.0 - 2.0 * t)


def _ease_out_cubic(t):
    t = _clamp(t, 0.0, 1.0)
    inv = 1.0 - t
    return 1.0 - inv * inv * inv


def _ease_in_out_cubic(t):
    t = _clamp(t, 0.0, 1.0)
    if t < 0.5:
        return 4.0 * t * t * t
    return 1.0 - ((-2.0 * t + 2.0) ** 3) * 0.5


def _ease_in_out_quad(t):
    t = _clamp(t, 0.0, 1.0)
    if t < 0.5:
        return 2.0 * t * t
    return 1.0 - ((-2.0 * t + 2.0) ** 2) * 0.5


def _lerp(a, b, t):
    return a + (b - a) * t


def _lerp_rgb(c0, c1, t):
    return (
        c0[0] + (c1[0] - c0[0]) * t,
        c0[1] + (c1[1] - c0[1]) * t,
        c0[2] + (c1[2] - c0[2]) * t,
    )


def _hash2(ix, iy):
    h = (ix * 374761393 + iy * 668265263) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    h = h ^ (h >> 16)
    return h / 4294967296.0


def _noise2(x, y):
    ix = math.floor(x)
    iy = math.floor(y)
    fx = x - ix
    fy = y - iy
    ux = fx * fx * (3.0 - 2.0 * fx)
    uy = fy * fy * (3.0 - 2.0 * fy)
    a = _hash2(ix, iy)
    b = _hash2(ix + 1, iy)
    c = _hash2(ix, iy + 1)
    d = _hash2(ix + 1, iy + 1)
    return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy


def _noise1(x):
    ix = math.floor(x)
    fx = x - ix
    u = fx * fx * (3.0 - 2.0 * fx)
    return _lerp(_hash2(ix, 17), _hash2(ix + 1, 17), u)


def _fbm2(x, y):
    return 0.65 * _noise2(x, y) + 0.35 * _noise2(x * 2.13 + 7.3, y * 2.13 - 4.1)


def _pack_cell(ch_code, r, g, b):
    if ch_code == 32:
        return SPACE_PACK
    qr = (int(r) // RGB_STEP) * RGB_STEP
    qg = (int(g) // RGB_STEP) * RGB_STEP
    qb = (int(b) // RGB_STEP) * RGB_STEP
    qr = 255 if qr > 255 else (0 if qr < 0 else qr)
    qg = 255 if qg > 255 else (0 if qg < 0 else qg)
    qb = 255 if qb > 255 else (0 if qb < 0 else qb)
    return (ch_code << 24) | (qr << 16) | (qg << 8) | qb


def _build_stars(count=185):
    stars = []
    state = 0x5DEECE66D
    for idx in range(count):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        angle = (state / 2147483648.0) * math.tau
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        rad0 = 0.14 + (state / 2147483648.0) * 1.15
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        z0 = 0.04 + (state / 2147483648.0) * 0.96
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        speed = 0.50 + (state / 2147483648.0) * 0.65
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        flare_phase = (state / 2147483648.0) * math.tau
        is_flare = (idx % 6) == 0
        stars.append((math.cos(angle), math.sin(angle), rad0, z0, speed, is_flare, flare_phase))
    return stars


EYE_CX = 0.34
EYE_CY = 0.02
W_HALF = 0.58       # Hero right eye: inner=-0.24, outer=+0.92 (width=1.16)
EYE_L_CX = -1.62    # Far left eye in ~14 deg 3/4 view: inner=-1.14, outer=-2.10
W_HALF_L = 0.48
NOSE_CX = -0.69


def _face_height(u, v):
    """3D anatomical relief z(u, v) for an East Asian woman's upper-mid face close-up."""
    hu = (u + 0.62) / 2.35
    hv = (v - 0.06) / 2.25
    z = 0.78 * math.sqrt(max(0.0, 1.0 - 0.60 * hu * hu - 0.24 * hv * hv))

    # Slender East Asian nasal bridge centered between inner corners (u ~ -0.69), curving to tip below.
    nose_c = NOSE_CX + 0.02 * _clamp(v, -0.2, 0.9)
    nose_w = 0.24 + 0.08 * _smoothstep(0.0, 0.85, v)
    dn = (u - nose_c) / nose_w
    z += 0.22 * math.exp(-dn * dn) * _smoothstep(-0.45, 0.15, v) * _smoothstep(1.22, 0.82, v)

    # Opposite far-cheek wrap.
    if u < -0.95:
        z -= 0.15 * _smoothstep(-0.95, -1.95, u)

    # Shallow orbital hollows around both eyes.
    z -= 0.048 * math.exp(-(((u - EYE_CX) / 0.62) ** 2 + ((v - 0.00) / 0.28) ** 2))
    z -= 0.042 * math.exp(-(((u - EYE_L_CX) / 0.52) ** 2 + ((v - 0.00) / 0.26) ** 2))

    # Soft forehead & brow arch (gently sculpted, not flat across the top).
    z += 0.055 * math.exp(-(((u - 0.10) / 0.95) ** 2 + ((v + 0.46) / 0.22) ** 2))
    z += 0.040 * math.exp(-(((u + 1.45) / 0.65) ** 2 + ((v + 0.46) / 0.22) ** 2))

    # Subtle East Asian lower-lid aegyo-sal pillow beneath both lower lashlines.
    z += 0.046 * math.exp(-(((u - EYE_CX) / 0.44) ** 2 + ((v - 0.24) / 0.08) ** 2))
    z += 0.034 * math.exp(-(((u - EYE_L_CX) / 0.36) ** 2 + ((v - 0.23) / 0.075) ** 2))

    # High malar cheekbone highlights.
    z += 0.150 * math.exp(-(((u - 0.58) / 0.60) ** 2 + ((v - 0.56) / 0.36) ** 2))
    z += 0.095 * math.exp(-(((u + 1.62) / 0.48) ** 2 + ((v - 0.54) / 0.36) ** 2))

    # Subtle rounded nasal tip bulb.
    z += 0.11 * math.exp(-(((u - nose_c) / 0.22) ** 2 + ((v - 0.88) / 0.14) ** 2))

    if u > 0.98:
        z -= 0.20 * _smoothstep(0.98, 1.70, u)
    return z


def _build_face_cache():
    """Precompute static 3D facial normals & vignette for fast dynamic studio lighting."""
    nx_n, ny_n = 129, 89
    u_min, u_max = -2.65, 2.25
    v_min, v_max = -1.45, 1.45
    du = (u_max - u_min) / (nx_n - 1)
    dv = (v_max - v_min) / (ny_n - 1)
    eps = 0.045
    table = [None] * (nx_n * ny_n)
    idx = 0
    for j in range(ny_n):
        v = v_min + j * dv
        edge_v = _smoothstep(0.55, 1.24, abs(v - 0.04))
        for i in range(nx_n):
            u = u_min + i * du
            dzdu = (_face_height(u + eps, v) - _face_height(u - eps, v)) / (2.0 * eps)
            dzdv = (_face_height(u, v + eps) - _face_height(u, v - eps)) / (2.0 * eps)
            inv = 1.0 / math.sqrt(dzdu * dzdu + dzdv * dzdv + 1.0)
            nx, ny, nz = -dzdu * inv, -dzdv * inv, inv

            edge_u = _smoothstep(1.05, 2.18, abs(u + 0.34))
            left_wrap = _smoothstep(-1.72, -2.24, u)
            vig = _clamp((1.0 - 0.56 * edge_u) * (1.0 - 0.74 * edge_v) * (1.0 - 0.65 * left_wrap), 0.0, 1.0)

            nose_ridge = math.exp(-(((u - NOSE_CX) / 0.15) ** 2)) * _smoothstep(-0.18, 0.24, v) * _smoothstep(1.14, 0.84, v)
            nose_tip_sh = math.exp(-(((u - NOSE_CX) / 0.22) ** 2 + ((v - 1.04) / 0.07) ** 2))
            nose_side = math.exp(-(((u - (NOSE_CX - 0.26)) / 0.22) ** 2)) * _smoothstep(-0.15, 0.25, v) * _smoothstep(1.02, 0.70, v)
            sculpt_mul = (1.0 - 0.20 * nose_side - 0.28 * nose_tip_sh) * vig
            table[idx] = (nx, ny, nz, vig, nose_ridge, sculpt_mul)
            idx += 1
    return table, nx_n, ny_n, u_min, v_min, 1.0 / du, 1.0 / dv


FACE_CACHE = _build_face_cache()
SHIMMER_LUT = [0.032 * math.sin(i * math.tau / 32.0) for i in range(32)]
STARS = _build_stars(185)

# Capsule stroke segments (x0, y0, x1, y1) for razor-sharp geometric wordmark "GENIK".
_GENIK_LETTERS = (
    (-1.08, (  # G
        (-0.10, -0.36, 0.14, -0.36),
        (-0.10, -0.36, -0.18, -0.20),
        (-0.18, -0.20, -0.18, 0.20),
        (-0.18, 0.20, -0.10, 0.36),
        (-0.10, 0.36, 0.14, 0.36),
        (0.16, 0.03, 0.16, 0.32),
        (0.01, 0.03, 0.16, 0.03),
    )),
    (-0.52, (  # E
        (-0.15, -0.36, -0.15, 0.36),
        (-0.15, -0.36, 0.16, -0.36),
        (-0.15, 0.00, 0.10, 0.00),
        (-0.15, 0.36, 0.16, 0.36),
    )),
    (0.04, (   # N
        (-0.16, -0.36, -0.16, 0.36),
        (-0.16, -0.36, 0.16, 0.36),
        (0.16, -0.36, 0.16, 0.36),
    )),
    (0.49, (   # I
        (0.0, -0.36, 0.0, 0.36),
        (-0.08, -0.36, 0.08, -0.36),
        (-0.08, 0.36, 0.08, 0.36),
    )),
    (0.95, (   # K
        (-0.16, -0.36, -0.16, 0.36),
        (-0.14, 0.04, 0.17, -0.36),
        (-0.03, -0.08, 0.18, 0.36),
    )),
)


def _genik_sdf(u, v):
    """Exact capsule SDF for centered wordmark 'GENIK' (v centered near -0.06)."""
    ly = v + 0.06
    if abs(ly) > 0.65 or abs(u) > 1.55:
        return 1.0
    best_d2 = 99.0
    for cx, segs in _GENIK_LETTERS:
        lx = u - cx
        if abs(lx) > 0.42:
            continue
        for x0, y0, x1, y1 in segs:
            dx = x1 - x0
            dy = y1 - y0
            px = lx - x0
            py = ly - y0
            denom = dx * dx + dy * dy
            t = (px * dx + py * dy) / denom
            if t < 0.0:
                t = 0.0
            elif t > 1.0:
                t = 1.0
            rx = px - dx * t
            ry = py - dy * t
            d2 = rx * rx + ry * ry
            if d2 < best_d2:
                best_d2 = d2
    return math.sqrt(best_d2) - 0.052


def _heart_sdf(u, v, scale_h=1.08):
    """Exact Euclidean SDF for a classic romantic heart centered near (0, -0.06)."""
    s = 0.88 * scale_h
    px = abs(u / s)
    py = (0.44 - v) / s
    if py + px > 1.0:
        d = math.hypot(px - 0.25, py - 0.75) - 0.35355339
    else:
        ax1, ay1 = px, py - 1.0
        m = 0.5 * max(px + py, 0.0)
        ax2, ay2 = px - m, py - m
        d1 = ax1 * ax1 + ay1 * ay1
        d2 = ax2 * ax2 + ay2 * ay2
        d = math.sqrt(d1 if d1 < d2 else d2)
        if px < py:
            d = -d
    return d * s


def _sample_face_lighting(u, v, light_dx, light_dy):
    table, nx_n, ny_n, u_min, v_min, inv_du, inv_dv = FACE_CACHE
    gx = (u - u_min) * inv_du
    gy = (v - v_min) * inv_dv
    if gx <= 0.0 or gx >= nx_n - 1 or gy <= 0.0 or gy >= ny_n - 1:
        return 0.0, 0.0, 0.0
    ix = int(gx)
    iy = int(gy)
    tx = gx - ix
    ty = gy - iy
    row0 = iy * nx_n + ix
    row1 = row0 + nx_n
    a, b, c, d = table[row0], table[row0 + 1], table[row1], table[row1 + 1]
    itx, ity = 1.0 - tx, 1.0 - ty
    w00, w10, w01, w11 = itx * ity, tx * ity, itx * ty, tx * ty
    nx = a[0] * w00 + b[0] * w10 + c[0] * w01 + d[0] * w11
    ny = a[1] * w00 + b[1] * w10 + c[1] * w01 + d[1] * w11
    nz = a[2] * w00 + b[2] * w10 + c[2] * w01 + d[2] * w11
    vig = a[3] * w00 + b[3] * w10 + c[3] * w01 + d[3] * w11
    nose_ridge = a[4] * w00 + b[4] * w10 + c[4] * w01 + d[4] * w11
    sculpt_mul = a[5] * w00 + b[5] * w10 + c[5] * w01 + d[5] * w11

    ndotl = nx * (-0.30 + light_dx) + ny * (-0.34 + light_dy) + nz * 0.89
    if ndotl < 0.0:
        ndotl = 0.0
    fill = nx * 0.46 + ny * 0.18 + nz * 0.87
    if fill < 0.0:
        fill = 0.0
    spec_d = nx * (-0.12 + light_dx * 0.4) + ny * (-0.18) + nz * 0.975
    spec = (spec_d ** 18) if spec_d > 0.0 else 0.0

    shade = (0.14 + 0.68 * (ndotl ** 1.15) + 0.16 * fill + 0.22 * spec + 0.12 * nose_ridge) * sculpt_mul
    return _clamp(shade, 0.0, 1.05), _clamp((spec + 0.22 * nose_ridge) * vig, 0.0, 1.0), vig


def _lid_bounds_eye(uw, cx, w_half, side, open_amt, iris_cx, smile_lift):
    xn_dir = ((uw - cx) / w_half) * side
    if xn_dir < -1.0 or xn_dir > 1.0:
        return None
    t = (xn_dir + 1.0) * 0.5
    v_axis = EYE_CY + 0.070 * (1.0 - 2.0 * t) + 0.012 * math.sin(t * math.pi)
    v_seam = v_axis + 0.022 * math.sin(t * math.pi)
    arch_top = (max(0.0, t) ** 0.76) * (max(0.0, 1.0 - t) ** 1.04) * 3.55
    arch_bot = (max(0.0, t) ** 1.08) * (max(0.0, 1.0 - t) ** 0.72) * 3.55
    cornea_bulge = 0.018 * math.exp(-((uw - iris_cx) / 0.20) ** 2) * open_amt
    scale_h = w_half / W_HALF
    h_top = (0.195 + cornea_bulge) * scale_h * open_amt * arch_top
    h_bot = (0.198 - 0.024 * smile_lift) * scale_h * open_amt * arch_bot
    yt = v_seam * (1.0 - open_amt) + (v_axis - h_top) * open_amt
    yb = (v_seam + 0.015 * (1.0 - open_amt)) * (1.0 - open_amt) + (v_axis + h_bot) * open_amt
    return yt, yb, xn_dir, t


def _eyebrow_sample(u, v, brow_lift):
    if -0.28 <= u <= 1.12:
        t = (u + 0.28) / 1.40
        side = 1.0
        arch = math.sin(min(1.0, t / 0.60) * math.pi * 0.5) if t < 0.60 else math.cos(((t - 0.60) / 0.40) * math.pi * 0.5)
        v_brow = -0.34 - 0.112 * (arch ** 1.1) - brow_lift
    elif -2.26 <= u <= -1.12:
        t = (-1.12 - u) / 1.14
        side = -1.0
        arch = math.sin(min(1.0, t / 0.60) * math.pi * 0.5) if t < 0.60 else math.cos(((t - 0.60) / 0.40) * math.pi * 0.5)
        v_brow = -0.34 - 0.102 * (arch ** 1.1) - brow_lift
    else:
        return 0.0, 0

    half_h = (0.038 * _smoothstep(0.0, 0.20, t) + 0.020) * (1.0 - 0.64 * _smoothstep(0.56, 1.0, t))
    dv = v - v_brow
    if abs(dv) > half_h * 1.45:
        return 0.0, 0
    env = max(0.0, 1.0 - (dv / max(1e-4, half_h)) ** 2)
    head_soft = _smoothstep(0.0, 0.18, t)
    tail_soft = _smoothstep(1.0, 0.80, t)
    lean = (-0.38 + 1.28 * t) * side
    u_hair = u - lean * dv
    hair_wave = 0.5 + 0.5 * math.cos(u_hair * 56.0 + 0.7 * _noise1(u_hair * 12.0))
    dens = env * (0.64 + 0.36 * hair_wave) * (0.56 + 0.44 * head_soft) * (0.44 + 0.56 * tail_soft)
    if dens < 0.18:
        return 0.0, 0
    if t < 0.24:
        ch = 47 if side > 0 else 92   # '/' or '\'
    elif t < 0.68:
        ch = 35 if dens > 0.62 else (61 if dens > 0.42 else 45)  # '#', '=', '-'
    else:
        ch = 92 if side > 0 else 47
    return _clamp(dens, 0.0, 1.0), ch


def _hair_mask(u, v, sway):
    """Sleek dark flowing hair framing right temple/cheek and far-left silhouette."""
    curve_r = 1.28 + 0.15 * math.sin(v * 1.6 + 0.4 + sway * 0.22) - 0.34 * _smoothstep(-0.20, -0.92, v)
    bang_r = -0.56 + 0.24 * _smoothstep(0.42, 1.35, u)
    curve_l = -2.14 - 0.12 * math.sin(v * 1.5 + 0.8 + sway * 0.20) + 0.24 * _smoothstep(-0.25, -0.90, v)

    in_r = u >= curve_r - 0.14
    in_bang = v < bang_r and u > 0.22
    in_l = u <= curve_l + 0.14
    if not in_r and not in_bang and not in_l:
        return 0.0, 0.0, 0

    if in_l:
        t_in = _smoothstep(curve_l + 0.14, curve_l - 0.16, u)
        strand = 0.5 + 0.5 * math.sin((u - curve_l) * 18.0 - math.sin(v * 2.0 + sway * 0.3) * 1.8)
        outer = _smoothstep(-2.75, -2.22, u) * _smoothstep(-1.22, -0.78, v) * _smoothstep(1.18, 0.72, v)
        cover = _clamp(t_in * outer * (0.62 + 0.38 * strand), 0.0, 1.0)
        if cover < 0.08:
            return 0.0, 0.0, 0
        sheen = (max(0.0, math.sin(v * 2.4 + 0.5)) ** 2) * strand * 0.65
        return cover, sheen, (47 if strand > 0.40 else 124)

    t_side = _smoothstep(curve_r - 0.14, curve_r + 0.16, u) if in_r else 0.0
    t_bang = _smoothstep(bang_r + 0.14, bang_r - 0.16, v) * _smoothstep(0.22, 0.80, u) if in_bang else 0.0
    t_in = t_side if t_side > t_bang else t_bang

    strand_coord = (u - curve_r) * 19.0 + math.sin(v * 2.1 + sway * 0.35) * 1.9
    strand = 0.5 + 0.5 * math.sin(strand_coord + 0.7 * _noise1(v * 4.5))
    outer_fade = _smoothstep(2.15, 1.48, u) * _smoothstep(-1.24, -0.80, v) * _smoothstep(1.20, 0.74, v)
    cover = _clamp(t_in * outer_fade * (0.62 + 0.38 * strand), 0.0, 1.0)
    if cover < 0.08:
        return 0.0, 0.0, 0
    sheen = (max(0.0, math.sin(v * 2.4 + 0.6)) ** 2) * strand * _smoothstep(curve_r + 0.34, curve_r + 0.02, u)
    slope = 0.15 * 1.6 * math.cos(v * 1.6 + 0.4)
    if in_bang:
        ch = 47 if strand > 0.38 else 58   # '/' or ':'
    elif slope > 0.06:
        ch = 47 if strand > 0.35 else 124
    elif slope < -0.06:
        ch = 92 if strand > 0.35 else 124
    else:
        ch = 124 if strand > 0.38 else 58
    return cover, sheen, ch


class GridGeometry:
    """Precomputed aspect-corrected screen coordinates and dither indices for a terminal size."""

    def __init__(self, cols, rows):
        self.cols = cols
        self.rows = rows
        self.total = cols * rows
        self.cx = (cols - 1) * 0.5
        self.cy = (rows - 1) * 0.5
        self.base_scale = min(cols * 0.38, rows * 0.84)
        self.cosmos_scale = min(cols * 0.44, rows * 0.90)
        inv_cs = 1.0 / max(1.0, self.cosmos_scale)

        self.u_off = [c - self.cx for c in range(cols)]
        self.v_off = [(r - self.cy) * 2.0 for r in range(rows)]
        self.scan_row = [1.0 if (r & 1) == 0 else 0.86 for r in range(rows)]

        self.r_scr = [0.0] * self.total
        self.noise_thresh = [0.0] * self.total
        self.shimmer_idx = [0] * self.total
        self.skin_micro = [0.0] * self.total

        idx = 0
        for row_idx in range(rows):
            vs = self.v_off[row_idx] * inv_cs
            for col_idx in range(cols):
                us = self.u_off[col_idx] * inv_cs
                self.r_scr[idx] = math.hypot(us, vs)
                self.skin_micro[idx] = (_fbm2(us * 4.5 + 9.1, vs * 4.5 + 3.7) - 0.5) * 0.04
                self.noise_thresh[idx] = _hash2(col_idx * 13 + 7, row_idx * 29 + 3)
                self.shimmer_idx[idx] = ((col_idx * 73856093) ^ (row_idx * 19349663)) & 31
                idx += 1

        self.max_r = max(
            math.hypot(self.u_off[0] * inv_cs, self.v_off[0] * inv_cs),
            math.hypot(self.u_off[-1] * inv_cs, self.v_off[0] * inv_cs),
        )


class SplashRenderer:
    """Renders an East Asian female portrait close-up -> dynamic eye contact -> pupil zoom -> star tunnel."""

    R_IRIS = 0.222
    R_PUPIL_BASE = 0.066

    def __init__(self, version=""):
        self.version = version.strip()
        self.geom = None
        self.prev_cells = None

    def ensure_geom(self, cols, rows):
        if self.geom is None or self.geom.cols != cols or self.geom.rows != rows:
            self.geom = GridGeometry(cols, rows)
            self.prev_cells = None
        return self.geom

    def _choreography(self, p):
        """Return animated eyelids, synchronized gaze, brow & cheek expression, head tilt, and push-in."""
        if p < 0.09:
            open_amt = 0.0
        elif p < 0.18:
            open_amt = 0.90 * _ease_out_cubic((p - 0.09) / 0.09)
        elif p < 0.255:
            open_amt = 0.90
        elif p < 0.290:
            open_amt = 0.90 * (1.0 - _ease_in_out_quad((p - 0.255) / 0.035))
        elif p < 0.335:
            open_amt = _ease_out_cubic((p - 0.290) / 0.045)
        else:
            open_amt = 1.0

        # Dynamic living gaze: down-left -> curious upper-right glance -> direct eye contact.
        if p < 0.165:
            gaze_x, gaze_y = -0.155, 0.032
        elif p < 0.25:
            tg = _ease_in_out_cubic((p - 0.165) / 0.085)
            gaze_x = _lerp(-0.155, 0.135, tg)
            gaze_y = _lerp(0.032, -0.022, tg)
        elif p < 0.375:
            tl = _ease_in_out_cubic((p - 0.25) / 0.125)
            gaze_x = _lerp(0.135, 0.0, tl)
            gaze_y = _lerp(-0.022, 0.0, tl)
        else:
            gaze_x, gaze_y = 0.0, 0.0

        # Living pupillary constriction + expressive brow & lower-lid smile lift.
        pupil_scale = 1.18 if p < 0.22 else _lerp(1.18, 0.94, _smoothstep(0.22, 0.41, p))
        if p > 0.44:
            pupil_scale = _lerp(0.94, 1.02, _smoothstep(0.44, 0.62, p))
        brow_lift = 0.028 * _smoothstep(0.19, 0.25, p) * (1.0 - _smoothstep(0.27, 0.32, p))
        brow_lift += 0.026 * _smoothstep(0.31, 0.40, p) * (1.0 - _smoothstep(0.55, 0.72, p))
        smile_lift = _smoothstep(0.32, 0.43, p) * (1.0 - _smoothstep(0.50, 0.66, p))

        # Dynamic head turn, gentle roll tilt following gaze, and breathing motion.
        settle = _ease_in_out_cubic(_clamp((p - 0.05) / 0.34, 0.0, 1.0))
        breath = 0.015 * math.sin(p * 18.0) * (1.0 - _smoothstep(0.42, 0.55, p))
        head_dx = -0.09 * (1.0 - settle) + gaze_x * 0.18
        head_dy = -0.038 * (1.0 - settle) + gaze_y * 0.14 + breath
        head_roll = 0.042 * (1.0 - settle) - gaze_x * 0.15

        if p <= 0.43:
            zoom = 1.0
            pan = 0.0
        elif p >= 0.78:
            zoom = 18.0
            pan = 1.0
        else:
            zp = (p - 0.43) / 0.35
            zp_e = 0.56 * (zp ** 1.40) + 0.44 * _ease_in_out_cubic(zp)
            zoom = 18.0 ** (zp_e ** 1.20)
            pan = _smoothstep(0.0, 0.34, zp)

        iris_wx = EYE_CX + gaze_x
        iris_wy = EYE_CY - 0.006 + gaze_y
        cam_cx = _lerp(-0.28, iris_wx, pan)
        cam_cy = _lerp(0.02, iris_wy, pan)
        return open_amt, gaze_x, gaze_y, pupil_scale, brow_lift, smile_lift, head_dx, head_dy, head_roll, zoom, cam_cx, cam_cy

    def render_cells(self, p, frame_idx, cols, rows):
        geom = self.ensure_geom(cols, rows)
        cells = [SPACE_PACK] * geom.total
        shimmer_off = frame_idx & 31

        (
            open_amt,
            gaze_x,
            gaze_y,
            pupil_scale,
            brow_lift,
            smile_lift,
            head_dx,
            head_dy,
            head_roll,
            zoom,
            cam_cx,
            cam_cy,
        ) = self._choreography(p)

        r_pupil = self.R_PUPIL_BASE * pupil_scale
        scale = geom.base_scale * zoom
        inv_s = 1.0 / max(1.0, scale)
        r_pupil_scr = (r_pupil * scale) / max(1.0, geom.cosmos_scale)
        pupil_covers_screen = p >= 0.78 or r_pupil_scr > geom.max_r + 0.14
        end_fade = 1.0 if p < 0.97 else _clamp(1.0 - (p - 0.97) / 0.03, 0.0, 1.0)

        if not pupil_covers_screen:
            self._render_portrait_and_eye(
                cells,
                geom,
                p,
                inv_s,
                open_amt,
                gaze_x,
                gaze_y,
                r_pupil,
                brow_lift,
                smile_lift,
                head_dx,
                head_dy,
                head_roll,
                zoom,
                cam_cx,
                cam_cy,
                shimmer_off,
            )

        if p >= 0.64:
            self._render_cosmos_and_core(cells, geom, p, r_pupil_scr, pupil_covers_screen, end_fade)

        if p >= 0.85:
            self._render_banner(cells, geom, p, end_fade)

        return cells

    def _render_portrait_and_eye(
        self,
        cells,
        geom,
        p,
        inv_s,
        open_amt,
        gaze_x,
        gaze_y,
        r_pupil,
        brow_lift,
        smile_lift,
        head_dx,
        head_dy,
        head_roll,
        zoom,
        cam_cx,
        cam_cy,
        shimmer_off,
    ):
        cols = geom.cols
        rows = geom.rows
        u_off = geom.u_off
        v_off = geom.v_off
        skin_micro = geom.skin_micro
        noise_thresh = geom.noise_thresh
        shimmer_idx = geom.shimmer_idx

        appear = _smoothstep(0.00, 0.10, p)
        noise_fade = 1.0 - _smoothstep(0.04, 0.12, p)
        light_sweep = _smoothstep(0.02, 0.18, p)
        light_dx = 0.16 * (1.0 - light_sweep) - gaze_x * 0.22
        light_dy = 0.08 * (1.0 - light_sweep)
        seam_vis = _smoothstep(0.02, 0.09, p)
        grade_lime = _smoothstep(0.48, 0.62, p)
        grade_emerald = _smoothstep(0.58, 0.76, p)
        spec_fade = 1.0 - _smoothstep(0.58, 0.72, p)

        sway = p * 8.0
        cr, sr = math.cos(head_roll), math.sin(head_roll)
        u0_cols = [cam_cx + uo * inv_s + head_dx - EYE_CX for uo in u_off]

        idx = 0
        for row_idx in range(rows):
            v0 = cam_cy + v_off[row_idx] * inv_s + head_dy - EYE_CY
            bayer_row = BAYER2X2[row_idx & 1]
            for col_idx in range(cols):
                u0 = u0_cols[col_idx]
                uw = u0 * cr + v0 * sr + EYE_CX
                vw = -u0 * sr + v0 * cr + EYE_CY
                shim = SHIMMER_LUT[(shimmer_idx[idx] + shimmer_off) & 31]

                eye_hit = None
                lids_r = _lid_bounds_eye(uw, EYE_CX, W_HALF, 1.0, open_amt, EYE_CX + gaze_x, smile_lift)
                if lids_r is not None:
                    eye_hit = (lids_r, EYE_CX, W_HALF, 1.0, 1.0)
                elif zoom < 2.2:
                    lids_l = _lid_bounds_eye(uw, EYE_L_CX, W_HALF_L, -1.0, open_amt, EYE_L_CX + gaze_x * 0.85, smile_lift)
                    if lids_l is not None:
                        far_dim = _clamp(_smoothstep(-2.08, -1.18, uw) * 0.76 + 0.18, 0.0, 0.88)
                        eye_hit = (lids_l, EYE_L_CX, W_HALF_L, -1.0, far_dim)

                # 1. Inside Eye Opening (pupil, directional radial iris, catchlights, bright sclera).
                if eye_hit is not None and open_amt > 0.02 and eye_hit[0][0] < vw < eye_hit[0][1]:
                    (yt, yb, xn, t_eye), e_cx, e_wh, e_side, eye_dim = eye_hit
                    scale_e = e_wh / W_HALF
                    iris_cx = e_cx + gaze_x * scale_e
                    iris_cy = EYE_CY - 0.006 + gaze_y * scale_e
                    r_ir = self.R_IRIS * scale_e
                    r_pu = r_pupil * scale_e
                    du = uw - iris_cx
                    dv = vw - iris_cy
                    rw = math.hypot(du, dv)
                    d_top = vw - yt
                    d_bot = yb - vw

                    sp = 0.0
                    if spec_fade > 0.02 and rw < r_ir * 1.15:
                        d1 = math.hypot(uw - (iris_cx - 0.068 * scale_e + gaze_x * 0.18), vw - (iris_cy - 0.064 * scale_e + gaze_y * 0.18))
                        d2 = math.hypot(uw - (iris_cx + 0.082 * scale_e + gaze_x * 0.18), vw - (iris_cy + 0.056 * scale_e + gaze_y * 0.18))
                        if d1 < 0.062 * scale_e:
                            sp = max(sp, (1.0 - d1 / (0.062 * scale_e)) ** 1.15)
                        if d2 < 0.032 * scale_e:
                            sp = max(sp, 0.74 * (1.0 - d2 / (0.032 * scale_e)) ** 1.25)
                        sp *= spec_fade

                    if rw < r_pu and sp < 0.25:
                        if rw > r_pu * 0.85:
                            er = _lerp_rgb((14.0, 34.0, 20.0), (28.0, 118.0, 82.0), grade_emerald)
                            cells[idx] = _pack_cell(46, er[0] * appear * eye_dim, er[1] * appear * eye_dim, er[2] * appear * eye_dim)
                        else:
                            cells[idx] = SPACE_PACK
                        idx += 1
                        continue

                    ao = 0.32 + 0.68 * min(_clamp(d_top / 0.10, 0.0, 1.0), _clamp(d_bot / 0.035, 0.0, 1.0))

                    if rw < r_ir:
                        ir = _clamp((rw - r_pu) / max(1e-5, r_ir - r_pu), 0.0, 1.0)
                        theta = math.atan2(dv, du)
                        f1 = math.sin(theta * 28.0 + 1.5 * _noise1(theta * 6.0))
                        f2 = math.cos(theta * 57.0 - 1.0 * _noise1(theta * 12.0))
                        fiber = _clamp(0.50 + 0.36 * (0.65 * f1 + 0.35 * f2) + shim, 0.0, 1.0)

                        ang_n = abs(math.atan2(abs(dv), abs(du)))
                        if ir > 0.80:
                            ch_code = 64 if ir > 0.88 else 35
                        elif ir < 0.26:
                            ch_code = 42 if fiber > 0.5 else 58
                        else:
                            if ang_n < 0.38:
                                ch_code = 45 if fiber > 0.4 else 61
                            elif ang_n > 1.18:
                                ch_code = 124 if fiber > 0.4 else 58
                            elif (du * dv) > 0.0:
                                ch_code = 92 if fiber > 0.42 else 59
                            else:
                                ch_code = 47 if fiber > 0.42 else 59
                            if fiber > 0.82:
                                ch_code = 42

                        if ir < 0.28:
                            t_in = ir / 0.28
                            c_nat = _lerp_rgb((174.0, 224.0, 88.0), (54.0, 162.0, 86.0), t_in)
                            c_lim = _lerp_rgb((216.0, 255.0, 138.0), (88.0, 226.0, 112.0), t_in)
                            c_bio = _lerp_rgb((230.0, 255.0, 242.0), (64.0, 242.0, 168.0), t_in)
                            base = _lerp_rgb(_lerp_rgb(c_nat, c_lim, grade_lime), c_bio, grade_emerald)
                        elif ir < 0.80:
                            cd = _lerp_rgb(_lerp_rgb((18.0, 68.0, 42.0), (28.0, 118.0, 66.0), grade_lime), (16.0, 116.0, 86.0), grade_emerald)
                            cb = _lerp_rgb(_lerp_rgb((72.0, 206.0, 108.0), (124.0, 248.0, 136.0), grade_lime), (68.0, 255.0, 184.0), grade_emerald)
                            base = _lerp_rgb(cd, cb, fiber)
                        else:
                            t_limb = _smoothstep(0.80, 0.96, ir)
                            c_mid = _lerp_rgb(_lerp_rgb((24.0, 86.0, 52.0), (36.0, 128.0, 72.0), grade_lime), (20.0, 132.0, 96.0), grade_emerald)
                            c_edge = _lerp_rgb((8.0, 24.0, 16.0), (8.0, 34.0, 26.0), grade_emerald)
                            base = _lerp_rgb(c_mid, c_edge, t_limb)

                        ao_eff = ao + (1.0 - ao) * max(grade_lime, grade_emerald) * 0.68
                        rc, gc, bc = base[0] * ao_eff, base[1] * ao_eff, base[2] * ao_eff
                    else:
                        sph = _clamp(1.0 - 0.30 * (xn * xn), 0.48, 1.0)
                        sc_shade = sph * ao
                        sc_hi = _lerp_rgb((252.0, 248.0, 250.0), (210.0, 240.0, 232.0), grade_emerald * 0.55)
                        sc_lo = _lerp_rgb((152.0, 146.0, 158.0), (84.0, 124.0, 116.0), grade_emerald * 0.55)
                        rc, gc, bc = _lerp_rgb(sc_lo, sc_hi, sc_shade)
                        if t_eye < 0.14:
                            car_t = _smoothstep(0.14, 0.01, t_eye) * 0.55
                            rc += (208.0 - rc) * car_t
                            gc += (118.0 - gc) * car_t
                            bc += (118.0 - bc) * car_t
                        if rw < r_ir + 0.022:
                            lt = (rw - r_ir) / 0.022
                            rim_c = _lerp_rgb((12.0, 28.0, 18.0), (14.0, 52.0, 38.0), grade_emerald)
                            rc = rim_c[0] + (rc - rim_c[0]) * lt
                            gc = rim_c[1] + (gc - rim_c[1]) * lt
                            bc = rim_c[2] + (bc - rim_c[2]) * lt
                        ch_code = SCLERA_CODES[int(_clamp(0.36 + 0.62 * sc_shade, 0.0, 1.0) * SCLERA_MAX)]

                    if sp > 0.06:
                        rc += (255.0 - rc) * sp
                        gc += (254.0 - gc) * sp
                        bc += (252.0 - bc) * sp
                        if sp > 0.22:
                            ch_code = 64 if sp > 0.50 else 42

                    if d_top < inv_s * 1.15:
                        ch_code = 95 if abs(t_eye - 0.5) < 0.24 else (47 if (t_eye < 0.28) == (e_side > 0.0) else 92)
                        rc += (26.0 - rc) * 0.78
                        gc += (16.0 - gc) * 0.78
                        bc += (18.0 - bc) * 0.78
                    elif d_bot < inv_s * 0.55 and t_eye > 0.22 and abs(t_eye - 0.5) > 0.18:
                        ch_code = 92 if (t_eye < 0.28) == (e_side > 0.0) else 47
                        rc += (132.0 - rc) * 0.52
                        gc += (78.0 - gc) * 0.52
                        bc += (76.0 - bc) * 0.52

                    mul = appear * eye_dim
                    cells[idx] = _pack_cell(ch_code, rc * mul, gc * mul, bc * mul)
                    idx += 1
                    continue

                # 2. Surrounding 3D Face, Double Eyelid Crease, Lashes, Brows & Flowing Hair.
                shade, spec, vig = _sample_face_lighting(uw, vw, light_dx, light_dy)
                if vig < 0.025 and zoom < 2.2:
                    hair_cov, hair_sheen, hair_ch = _hair_mask(uw, vw, sway)
                    if hair_cov > 0.12:
                        hr = (20.0 + 56.0 * hair_sheen) * hair_cov * appear
                        hg = (15.0 + 43.0 * hair_sheen) * hair_cov * appear
                        hb = (20.0 + 48.0 * hair_sheen) * hair_cov * appear
                        cells[idx] = _pack_cell(hair_ch, hr, hg, hb)
                    else:
                        cells[idx] = SPACE_PACK
                    idx += 1
                    continue

                tone = _clamp(shade + skin_micro[idx], 0.0, 1.05)
                if tone < 0.34:
                    ts = tone / 0.34
                    rc, gc, bc = 28.0 + 110.0 * ts, 16.0 + 70.0 * ts, 18.0 + 54.0 * ts
                elif tone < 0.72:
                    ts = (tone - 0.34) / 0.38
                    rc, gc, bc = 138.0 + 84.0 * ts, 86.0 + 82.0 * ts, 72.0 + 74.0 * ts
                else:
                    ts = min(1.0, (tone - 0.72) / 0.28)
                    rc, gc, bc = 222.0 + 28.0 * ts, 168.0 + 50.0 * ts, 146.0 + 54.0 * ts

                if zoom < 3.5:
                    blush = 0.18 * math.exp(-(((uw - 0.58) / 0.52) ** 2 + ((vw - 0.58) / 0.36) ** 2))
                    rc += (232.0 - rc) * blush
                    gc += (130.0 - gc) * blush
                    bc += (126.0 - bc) * blush
                if spec > 0.02:
                    sp_a = spec * 0.45
                    rc += (254.0 - rc) * sp_a
                    gc += (234.0 - gc) * sp_a
                    bc += (222.0 - bc) * sp_a

                dith = (bayer_row[col_idx & 1] - 0.375) * 0.12
                dens = _clamp(tone * 0.84 + dith + shim * 0.25, 0.0, 1.0)
                ch_code = SKIN_CODES[int(dens * SKIN_MAX)]

                lash_hit = 0.0
                lash_ch = 0
                lash_rgb = (26.0, 16.0, 19.0)

                if eye_hit is not None:
                    (yt, yb, xn, t_eye), e_cx, e_wh, e_side, eye_dim = eye_hit
                    crease_gap = (0.040 + 0.036 * (t_eye ** 0.75)) * (0.45 + 0.55 * open_amt)
                    d_crease = abs(vw - (yt - crease_gap))
                    if vw <= yt and d_crease < 0.022 and t_eye > 0.08:
                        c_str = (1.0 - d_crease / 0.022) * _smoothstep(0.08, 0.28, t_eye) * seam_vis
                        ca = c_str * 0.58
                        rc += (104.0 - rc) * ca
                        gc += (62.0 - gc) * ca
                        bc += (56.0 - bc) * ca
                        if c_str > 0.44:
                            ch_code = 45 if abs(t_eye - 0.5) < 0.28 else 39

                    if zoom < 4.5:
                        d_up = yt - vw
                        if -0.015 <= d_up < 0.038:
                            lash_hit = (1.0 - max(0.0, d_up) / 0.038) * seam_vis * eye_dim
                            lash_ch = 95 if abs(t_eye - 0.5) < 0.24 else (47 if (t_eye < 0.24) == (e_side > 0.0) else 92)
                            lash_rgb = (36.0, 22.0, 24.0)
                        elif open_amt >= 0.25 and 0.16 <= t_eye <= 0.98 and 0.038 <= d_up < (0.042 + 0.065 * (t_eye ** 1.1)):
                            u_len = 0.042 + 0.065 * (t_eye ** 1.1)
                            hn = d_up / u_len
                            lean = (-0.25 + 1.45 * t_eye) * e_side
                            strand = 0.5 + 0.5 * math.cos((uw - lean * d_up) * 68.0)
                            if strand > 0.58 + 0.34 * hn:
                                lash_hit = (1.0 - 0.55 * hn) * 0.78 * eye_dim
                                lash_ch = 47 if lean > 0.2 else (92 if lean < -0.2 else 39)
                                lash_rgb = (34.0, 21.0, 24.0)
                        elif open_amt < 0.25 and 0.0 <= (vw - yt) < 0.038:
                            lash_hit = 0.85 * seam_vis * eye_dim
                            lash_ch = 95 if abs(t_eye - 0.5) < 0.3 else 44
                            lash_rgb = (36.0, 22.0, 24.0)

                        d_dn = vw - yb
                        if open_amt > 0.30 and 0.0 <= d_dn < 0.024 and 0.10 <= t_eye <= 0.94:
                            dl = (1.0 - d_dn / 0.024) * 0.48 * open_amt * eye_dim
                            if dl > lash_hit:
                                lash_hit = dl
                                lash_ch = 46 if t_eye < 0.4 else 44
                                lash_rgb = (138.0, 84.0, 80.0)

                elif zoom < 4.5:
                    ext_u = uw - (EYE_CX + W_HALF)
                    if 0.0 <= ext_u < 0.14:
                        v_wing = (EYE_CY - 0.070) - 0.28 * ext_u
                        if abs(vw - v_wing) < 0.022 * (1.0 - ext_u / 0.14):
                            lash_hit = 0.82 * (1.0 - ext_u / 0.14) * seam_vis
                            lash_ch = 47
                            lash_rgb = (36.0, 22.0, 24.0)

                if zoom < 4.5:
                    bd, bch = _eyebrow_sample(uw, vw, brow_lift)
                    if bd > 0.0:
                        br_r, br_g, br_b = (38.0, 24.0, 22.0) if bd > 0.55 else (64.0, 42.0, 38.0)
                        ba = bd * 0.88
                        rc += (br_r - rc) * ba
                        gc += (br_g - gc) * ba
                        bc += (br_b - bc) * ba
                        if bd > 0.30 and bch:
                            ch_code = bch

                if lash_hit > 0.06:
                    rc += (lash_rgb[0] - rc) * lash_hit
                    gc += (lash_rgb[1] - gc) * lash_hit
                    bc += (lash_rgb[2] - bc) * lash_hit
                    if lash_hit > 0.26 and lash_ch:
                        ch_code = lash_ch

                if zoom < 3.5:
                    hair_cov, hair_sheen, hair_ch = _hair_mask(uw, vw, sway)
                    if hair_cov > 0.04:
                        hr = 22.0 + 56.0 * hair_sheen
                        hg = 16.0 + 42.0 * hair_sheen
                        hb = 20.0 + 48.0 * hair_sheen
                        rc += (hr - rc) * hair_cov
                        gc += (hg - gc) * hair_cov
                        bc += (hb - bc) * hair_cov
                        if hair_cov > 0.30:
                            ch_code = hair_ch

                if noise_fade > 0.01 and noise_thresh[idx] > appear * 0.92:
                    if p < 0.04:
                        cells[idx] = SPACE_PACK
                        idx += 1
                        continue
                    fade_m = appear * (0.35 + 0.65 * (1.0 - noise_fade))
                    rc *= fade_m
                    gc *= fade_m
                    bc *= fade_m
                else:
                    rc *= appear
                    gc *= appear
                    bc *= appear

                if max(rc, gc, bc) < 9.0 or ch_code == 32:
                    cells[idx] = SPACE_PACK
                else:
                    cells[idx] = _pack_cell(ch_code, rc, gc, bc)
                idx += 1

    def _render_cosmos_and_core(self, cells, geom, p, r_pupil_scr, pupil_covers_screen, end_fade):
        cols = geom.cols
        rows = geom.rows
        cx = geom.cx
        cy = geom.cy
        scale = geom.cosmos_scale
        p4 = (p - 0.64) / 0.36
        space_vis = _smoothstep(0.64, 0.74, p) * end_fade
        if space_vis <= 0.01:
            return

        # 3D Parallax Star Tunnel + periodic cross-flashes.
        for cos_a, sin_a, rad0, z0, speed, is_flare, flare_phase in STARS:
            z = (z0 - p4 * speed * 1.75) % 1.0
            z_eff = 0.042 + 0.958 * z
            proj = 0.38 / z_eff
            su = cos_a * rad0 * proj
            sv = sin_a * rad0 * proj
            if not pupil_covers_screen and math.hypot(su, sv) >= r_pupil_scr * 0.92:
                continue

            scol = int(round(cx + su * scale))
            srow = int(round(cy + sv * scale * 0.5))
            if not (0 <= scol < cols and 0 <= srow < rows):
                continue

            near = 1.0 - z
            bright = _clamp((0.30 + 0.70 * near) * space_vis, 0.0, 1.0)
            flare_pulse = max(0.0, math.sin(p4 * 17.0 + flare_phase)) ** 4 if (is_flare and near > 0.28) else 0.0

            if flare_pulse > 0.30:
                c_core = 255.0 * end_fade
                c_arm = (200.0 + 55.0 * flare_pulse) * end_fade
                cells[srow * cols + scol] = _pack_cell(43, c_core, c_core, c_core)
                if scol - 1 >= 0:
                    cells[srow * cols + scol - 1] = _pack_cell(45, c_arm, c_arm, c_core)
                if scol + 1 < cols:
                    cells[srow * cols + scol + 1] = _pack_cell(45, c_arm, c_arm, c_core)
                if srow - 1 >= 0:
                    cells[(srow - 1) * cols + scol] = _pack_cell(124, c_arm, c_arm, c_core)
                if srow + 1 < rows:
                    cells[(srow + 1) * cols + scol] = _pack_cell(124, c_arm, c_arm, c_core)
                continue

            if near < 0.35:
                ch_code = 46
                rgb_s = (108.0 * bright, 114.0 * bright, 134.0 * bright)
            elif near < 0.65:
                ch_code = 58 if near < 0.50 else 43
                rgb_s = (182.0 * bright, 188.0 * bright, 208.0 * bright)
            elif near < 0.85:
                ch_code = 42
                rgb_s = (236.0 * bright, 240.0 * bright, 250.0 * bright)
            else:
                ch_code = 111
                rgb_s = (255.0 * bright, 250.0 * bright, 254.0 * bright)

            cells[srow * cols + scol] = _pack_cell(ch_code, rgb_s[0], rgb_s[1], rgb_s[2])

            if near > 0.64:
                for step_f, trail_ch, trail_lum in ((0.91, 58 if near > 0.82 else 46, 132.0), (0.83, 46, 78.0)):
                    t_col = int(round(cx + su * step_f * scale))
                    t_row = int(round(cy + sv * step_f * scale * 0.5))
                    if (t_col != scol or t_row != srow) and 0 <= t_col < cols and 0 <= t_row < rows:
                        t_idx = t_row * cols + t_col
                        if cells[t_idx] == SPACE_PACK:
                            tc = trail_lum * bright
                            cells[t_idx] = _pack_cell(trail_ch, tc, tc, tc * 1.08)

        # Glowing GENIK Wordmark -> Crimson/Soft-Rose Heart Morph (p = 0.66 -> 1.00).
        if p < 0.66:
            return
        pc = (p - 0.66) / 0.34
        alpha_shape = min(1.0, pc * 3.1) * end_fade
        if alpha_shape <= 0.02:
            return

        # Morph timeline: 0.66..0.77 pure GENIK -> 0.77..0.85 smooth morph -> 0.85..1.00 pulsing heart.
        morph_t = _smoothstep(0.77, 0.85, p)
        morph_ease = _ease_in_out_cubic(morph_t)
        # Double heartbeat ("lub-dub") once the heart has formed.
        beat1 = math.sin(((p - 0.85) / 0.042) * math.pi) if 0.85 <= p <= 0.892 else 0.0
        beat2 = 0.65 * math.sin(((p - 0.896) / 0.038) * math.pi) if 0.896 <= p <= 0.934 else 0.0
        beat = max(0.0, beat1, beat2)
        heart_scale = (0.72 + 0.33 * _ease_out_cubic(min(1.0, (p - 0.75) / 0.10))) * (1.0 + 0.085 * beat)
        genik_scale = 0.80 + 0.20 * _ease_out_cubic(min(1.0, (p - 0.66) / 0.09))
        # Pull outer letters smoothly inward as GENIK transforms into the heart.
        gx_compress = _lerp(1.0, 0.54, morph_ease) / genik_scale
        gy_scale = _lerp(1.0, 0.88, morph_ease) / genik_scale

        half_w = 1.48
        half_h = 0.92
        col_rad = int(math.ceil(half_w * scale)) + 1
        row_rad = int(math.ceil(half_h * scale * 0.5)) + 1
        c0 = max(0, int(math.floor(cx)) - col_rad)
        c1 = min(cols - 1, int(math.ceil(cx)) + col_rad)
        r0 = max(0, int(math.floor(cy - 0.04 * scale * 0.5)) - row_rad)
        r1 = min(rows - 1, int(math.ceil(cy - 0.04 * scale * 0.5)) + row_rad)

        r_arr = geom.r_scr
        u_off = geom.u_off
        v_off = geom.v_off
        scan_row = geom.scan_row
        shimmer_idx = geom.shimmer_idx
        inv_s = 1.0 / max(1.0, scale)
        shimmer_off = int(p * 100) & 31
        pupil_lim = 999.0 if pupil_covers_screen else r_pupil_scr * 0.94
        # Tight 1-cell halo on GENIK keeps letters razor-sharp; lush aura blooms on the heart!
        halo_w = _lerp(0.062, 0.24, morph_ease)
        aura_amp = _lerp(0.24, 0.44, morph_ease)
        color_rose = _smoothstep(0.75, 0.85, p)

        for row_idx in range(r0, r1 + 1):
            sv = v_off[row_idx] * inv_s
            sweep = 0.045 * math.sin(row_idx * 0.55 - p4 * 10.0)
            scan = _clamp(scan_row[row_idx] + sweep, 0.80, 1.0)
            row_off = row_idx * cols
            for col_idx in range(c0, c1 + 1):
                idx = row_off + col_idx
                if r_arr[idx] >= pupil_lim:
                    continue
                su = u_off[col_idx] * inv_s

                if morph_ease <= 0.001:
                    d = _genik_sdf(su / genik_scale, sv / genik_scale) * genik_scale
                    d_heart = 1.0
                elif morph_ease >= 0.999:
                    d_heart = _heart_sdf(su, sv, heart_scale)
                    d = d_heart
                else:
                    d_genik = _genik_sdf(su / gx_compress, sv * gy_scale) * min(gx_compress, 1.0)
                    d_heart = _heart_sdf(su, sv, heart_scale)
                    d = _lerp(d_genik, d_heart, morph_ease)

                if d >= halo_w:
                    continue

                if d <= 0.0:
                    depth = _clamp(-d / 0.24, 0.0, 1.0)
                    lobe_hl = max(0.0, 1.0 - math.hypot((su + 0.24) / 0.45, (sv + 0.22) / 0.40))
                    lum = _clamp((0.76 + 0.22 * depth + 0.16 * lobe_hl * morph_ease + 0.10 * beat) * alpha_shape * scan, 0.0, 1.0)
                else:
                    aura = (1.0 - d / halo_w) ** 2.2
                    lum = _clamp(aura_amp * aura * alpha_shape * scan, 0.0, 1.0)

                if lum <= 0.032:
                    continue

                # Color arc: luminous mint-emerald/pearl GENIK -> warm crimson & soft rose-pink heart!
                if lum >= 0.80:
                    c_em = _lerp_rgb((184.0, 255.0, 228.0), (248.0, 255.0, 252.0), (lum - 0.80) / 0.20)
                    c_rs = _lerp_rgb((255.0, 158.0, 192.0), (255.0, 228.0, 238.0), (lum - 0.80) / 0.20)
                elif lum >= 0.50:
                    c_em = _lerp_rgb((42.0, 232.0, 156.0), (184.0, 255.0, 228.0), (lum - 0.50) / 0.30)
                    c_rs = _lerp_rgb((232.0, 32.0, 78.0), (255.0, 146.0, 184.0), (lum - 0.50) / 0.30)
                elif lum >= 0.22:
                    c_em = _lerp_rgb((16.0, 138.0, 92.0), (42.0, 232.0, 156.0), (lum - 0.22) / 0.28)
                    c_rs = _lerp_rgb((152.0, 14.0, 48.0), (232.0, 32.0, 78.0), (lum - 0.22) / 0.28)
                else:
                    c_em = _lerp_rgb((6.0, 42.0, 28.0), (16.0, 138.0, 92.0), lum / 0.22)
                    c_rs = _lerp_rgb((48.0, 4.0, 18.0), (152.0, 14.0, 48.0), lum / 0.22)

                rgb_c = _lerp_rgb(c_em, c_rs, color_rose)
                shim = SHIMMER_LUT[(shimmer_idx[idx] + shimmer_off) & 31]
                dens = _clamp(lum * 0.96 + shim * 0.65, 0.05, 1.0)
                cells[idx] = _pack_cell(CORE_CODES[int(dens * CORE_MAX)], rgb_c[0], rgb_c[1], rgb_c[2])

    def _render_banner(self, cells, geom, p, end_fade):
        fade_in = _smoothstep(0.81, 0.89, p) * end_fade
        if fade_in <= 0.04:
            return
        cols = geom.cols
        rows = geom.rows

        title = "╭─[ ◉ ]─╮  remna-node-setup"
        subtitle = f"v{self.version}" if self.version else ""
        heart_bottom_row = int(round(geom.cy + 0.52 * geom.cosmos_scale * 0.5)) + 2
        banner_row = min(rows - (3 if subtitle else 2), max(int(round(geom.cy)) + 2, heart_bottom_row))

        def stamp_centered(row_y, text, accent_range, rgb_main, rgb_accent):
            if not (0 <= row_y < rows) or len(text) + 2 > cols:
                return
            start_x = (cols - len(text)) // 2
            pad_l = max(0, start_x - 2)
            pad_r = min(cols - 1, start_x + len(text) + 1)
            row_off = row_y * cols
            for x in range(pad_l, pad_r + 1):
                cells[row_off + x] = SPACE_PACK
            for i, ch in enumerate(text):
                if ch == " ":
                    continue
                r_c, g_c, b_c = rgb_accent if (accent_range[0] <= i < accent_range[1]) else rgb_main
                cells[row_off + start_x + i] = _pack_cell(ord(ch), r_c * fade_in, g_c * fade_in, b_c * fade_in)

        stamp_centered(banner_row, title, (0, 9), (255, 240, 246), (255, 96, 146))
        if subtitle:
            stamp_centered(banner_row + 1, subtitle, (0, 0), (208, 154, 174), (208, 154, 174))

    def encode_frame(self, cells, cols, rows):
        out = []
        prev = self.prev_cells
        if prev is None or len(prev) != len(cells):
            out.append("\033[H\033[2J")
            last_rgb = -1
            for r in range(rows):
                if r > 0:
                    out.append("\r\n")
                row_off = r * cols
                for c in range(cols):
                    cell = cells[row_off + c]
                    if cell == SPACE_PACK:
                        out.append(" ")
                        continue
                    ch_code = cell >> 24
                    rgb = cell & 0xFFFFFF
                    if rgb != last_rgb:
                        out.append(f"\033[38;2;{(rgb >> 16) & 255};{(rgb >> 8) & 255};{rgb & 255}m")
                        last_rgb = rgb
                    out.append(chr(ch_code))
            out.append("\033[0m")
            self.prev_cells = cells
            return "".join(out)

        last_rgb = -1
        cur_r = -1
        cur_c = -1
        for r in range(rows):
            row_off = r * cols
            c = 0
            while c < cols:
                if cells[row_off + c] == prev[row_off + c]:
                    c += 1
                    continue
                span_start = c
                span_end = c + 1
                while span_end < cols:
                    if cells[row_off + span_end] != prev[row_off + span_end]:
                        span_end += 1
                        continue
                    gap = 1
                    while span_end + gap < cols and gap < 4 and cells[row_off + span_end + gap] == prev[row_off + span_end + gap]:
                        gap += 1
                    if span_end + gap < cols and cells[row_off + span_end + gap] != prev[row_off + span_end + gap]:
                        span_end += gap + 1
                    else:
                        break
                if cur_r != r or cur_c != span_start:
                    out.append(f"\033[{r + 1};{span_start + 1}H")
                for col_i in range(span_start, span_end):
                    cell = cells[row_off + col_i]
                    if cell == SPACE_PACK:
                        out.append(" ")
                        continue
                    ch_code = cell >> 24
                    rgb = cell & 0xFFFFFF
                    if rgb != last_rgb:
                        out.append(f"\033[38;2;{(rgb >> 16) & 255};{(rgb >> 8) & 255};{rgb & 255}m")
                        last_rgb = rgb
                    out.append(chr(ch_code))
                cur_r = r
                cur_c = span_end
                c = span_end

        if out and last_rgb != -1:
            out.append("\033[0m")
        self.prev_cells = cells
        return "".join(out)


def _write_all(fd, payload):
    if not payload:
        return
    data = payload.encode("utf-8")
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            break
        view = view[written:]


def _drain_stdin(fd):
    try:
        while select.select([fd], [], [], 0.008)[0]:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            if b"\x03" in chunk:
                raise SplashSignal(signal.SIGINT)
    except OSError:
        pass


def _poll_input(fd, timeout):
    if fd is None:
        if timeout > 0.0:
            time.sleep(timeout)
        return False
    ready, _, _ = select.select([fd], [], [], max(0.0, timeout))
    if not ready:
        return False
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        return True
    if b"\x03" in chunk:
        raise SplashSignal(signal.SIGINT)
    if chunk:
        _drain_stdin(fd)
    return True


def play_splash(duration=DEFAULT_DURATION, version=""):
    if should_skip_splash():
        return 0

    size = shutil.get_terminal_size((80, 24))
    cols, rows = size.columns, size.lines
    if cols < MIN_COLS or rows < MIN_ROWS:
        return 0

    stdout_fd = sys.stdout.fileno()
    stdin_fd = sys.stdin.fileno() if sys.stdin.isatty() else None
    orig_termios = None
    termios_changed = False
    alt_active = False
    cursor_hidden = False
    resized = False
    interrupted_sig = 0

    old_sigint = signal.getsignal(signal.SIGINT)
    old_sigterm = signal.getsignal(signal.SIGTERM)
    old_sighup = signal.getsignal(signal.SIGHUP) if hasattr(signal, "SIGHUP") else None
    old_sigwinch = signal.getsignal(signal.SIGWINCH) if hasattr(signal, "SIGWINCH") else None

    def _on_signal(signum, _frame):
        raise SplashSignal(signum)

    def _on_resize(_signum, _frame):
        nonlocal resized
        resized = True

    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, _on_signal)
    if hasattr(signal, "SIGWINCH"):
        signal.signal(signal.SIGWINCH, _on_resize)

    renderer = SplashRenderer(version=version)
    frame_dt = 1.0 / TARGET_FPS

    try:
        if stdin_fd is not None:
            orig_termios = termios.tcgetattr(stdin_fd)
            tty.setcbreak(stdin_fd, termios.TCSANOW)
            termios_changed = True

        _write_all(stdout_fd, "\033[?1049h\033[?25l\033[H\033[2J")
        alt_active = True
        cursor_hidden = True

        start = time.monotonic()
        frame_idx = 0
        while True:
            if resized:
                resized = False
                new_size = shutil.get_terminal_size((cols, rows))
                cols, rows = new_size.columns, new_size.lines
                if cols < MIN_COLS or rows < MIN_ROWS:
                    break
                renderer.prev_cells = None

            now = time.monotonic()
            elapsed = now - start
            p = min(1.0, elapsed / duration)
            cells = renderer.render_cells(p, frame_idx, cols, rows)
            frame_str = renderer.encode_frame(cells, cols, rows)
            _write_all(stdout_fd, frame_str)

            if p >= 1.0:
                _poll_input(stdin_fd, 0.04)
                break

            frame_idx += 1
            next_t = start + frame_idx * frame_dt
            wait_s = max(0.0, min(next_t - time.monotonic(), duration - (time.monotonic() - start)))
            if _poll_input(stdin_fd, wait_s):
                break
    except (KeyboardInterrupt, SplashSignal) as exc:
        if isinstance(exc, SplashSignal):
            interrupted_sig = exc.signum
        else:
            interrupted_sig = signal.SIGINT
    finally:
        if termios_changed and stdin_fd is not None and orig_termios is not None:
            try:
                termios.tcsetattr(stdin_fd, termios.TCSADRAIN, orig_termios)
            except termios.error:
                pass
        restore = ["\033[0m"]
        if cursor_hidden:
            restore.append("\033[?25h")
        if alt_active:
            restore.append("\033[?1049l")
        try:
            _write_all(stdout_fd, "".join(restore))
        except OSError:
            pass
        signal.signal(signal.SIGINT, old_sigint)
        signal.signal(signal.SIGTERM, old_sigterm)
        if old_sighup is not None:
            signal.signal(signal.SIGHUP, old_sighup)
        if old_sigwinch is not None:
            signal.signal(signal.SIGWINCH, old_sigwinch)

    if interrupted_sig:
        return 128 + interrupted_sig
    return 0


def _run_self_check():
    renderer = SplashRenderer(version="0.0.0-test")
    last_frame = ""
    for p in (0.02, 0.09, 0.16, 0.24, 0.30, 0.38, 0.56, 0.68, 0.85, 0.94):
        cells = renderer.render_cells(p, int(p * 100), 80, 24)
        assert len(cells) == 80 * 24
        frame = renderer.encode_frame(cells, 80, 24)
        assert "\033[38;2;" in frame or p < 0.02
        last_frame = frame
    renderer.prev_cells = None
    final_full = renderer.encode_frame(renderer.render_cells(0.94, 94, 80, 24), 80, 24)
    assert "remna-node-setup" in final_full and "\033[38;2;" in last_frame
    return 0


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    duration = DEFAULT_DURATION
    version = ""
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--demo":
            duration = DEMO_DURATION
        elif arg == "--no-intro":
            return 0
        elif arg == "--self-check":
            return _run_self_check()
        elif arg == "--duration" and i + 1 < len(args):
            i += 1
            duration = max(0.05, float(args[i]))
        elif arg == "--version" and i + 1 < len(args):
            i += 1
            version = args[i]
        else:
            print(f"Неизвестный параметр: {arg}", file=sys.stderr)
            return 2
        i += 1
    return play_splash(duration=duration, version=version)


if __name__ == "__main__":
    sys.exit(main())
