"""3D LUT: bake a linear-space transform into a display-space .cube, apply it.

A Premiere/Resolve Input LUT maps display-encoded input -> display-encoded output.
So each grid node is decoded to linear, transformed, and re-encoded.
"""
from __future__ import annotations
import os
from pathlib import Path
import numpy as np
from scipy.interpolate import RegularGridInterpolator

from .colorspace import decode, encode


def gamut_guard(lut: np.ndarray, samples_enc: np.ndarray,
                fallback: np.ndarray, sigma: float = 2.5,
                ref_pct: float = 30.0) -> np.ndarray:
    """Blend `lut` toward a safe `fallback` in cube regions the source never covered.

    Every candidate is FIT and SCORED only on pixels sampled from the source
    frames, but the baked LUT spans the whole RGB cube. Outside the sampled
    cloud nothing constrains the winner — a degree-3 polynomial happily explodes
    there, and a lattice's unsupported nodes drift toward black — yet later
    frames of the clip WILL contain colours the sampled frames didn't (a flash,
    a neon sign, deep shadow). Those pixels then read garbage: the occasional
    "insane colours" failure.

    Fix at one choke point: histogram the sampled source pixels into the LUT
    grid, smooth lightly, and per node blend `lut` toward `fallback` (the
    gain-capped global MKL — smooth and sane over the whole cube) by how much
    data support the node has. Well-sampled nodes keep the winner bit-for-bit,
    so measured accuracy is untouched; unsupported nodes get the safe global
    look instead of extrapolation noise.
    """
    from scipy.ndimage import gaussian_filter
    size = lut.shape[0]
    pts = np.clip(np.asarray(samples_enc, dtype=np.float64).reshape(-1, 3), 0.0, 1.0)
    bins = np.linspace(0.0, 1.0, size + 1)
    hist, _ = np.histogramdd(pts, bins=(bins, bins, bins))   # indexed [r,g,b]
    support = gaussian_filter(hist, sigma=sigma, mode="nearest")
    pos = support[support > 1e-12]
    if pos.size == 0:
        return fallback.copy()
    ref = np.percentile(pos, ref_pct)
    if ref <= 0:
        ref = float(pos.mean()) or 1.0
    w = np.clip(support / ref, 0.0, 1.0)[..., None]
    return w * lut + (1.0 - w) * fallback


def lut_steepness(lut: np.ndarray, pct: float = 99.5) -> float:
    """The LUT's near-worst LOCAL slope (unitless; identity = 1).

    Steepness is what turns a match into visible damage on real footage: any
    segment steeper than ~6x stretches 8-bit quantisation and H.264 macroblock
    steps into hard posterised patches. Natural grades sit under ~3x."""
    size = lut.shape[0]
    mx = []
    for ax in range(3):
        d = np.abs(np.diff(lut, axis=ax)) * (size - 1)
        mx.append(d.max(axis=-1).ravel())
    return float(np.percentile(np.concatenate(mx), pct))


def steep_guard(lut: np.ndarray, fallback: np.ndarray, cap: float = 6.0) -> np.ndarray:
    """Emergency brake: SMOOTH the LUT until its near-worst local slope is under
    `cap`. A no-op for every sane match; only an exact-distribution map between a
    narrow and a wide distribution (the posterisation failure) gets softened.

    Smoothing (not blending away) is the transport-map regularisation the colour
    OT literature prescribes: it keeps the grade's structure and only shaves the
    local spikes that turn 8-bit / macroblock steps into posterised patches. If
    even repeated smoothing can't tame it, fall back to blending toward the
    smooth capped-MKL as a last resort."""
    from scipy.ndimage import gaussian_filter
    out = lut
    for _ in range(4):
        if lut_steepness(out) <= cap:
            return out
        out = np.stack([gaussian_filter(out[..., c], sigma=1.0, mode="nearest")
                        for c in range(3)], axis=-1)
    sa = lut_steepness(out)
    if sa > cap * 1.5:
        sb = lut_steepness(fallback)
        t = float(np.clip((cap - sb) / max(sa - sb, 1e-9), 0.0, 1.0))
        out = t * out + (1.0 - t) * fallback
    return out


def soft_gamut(lin: np.ndarray) -> np.ndarray:
    """Hue-preserving gamut mapping for out-of-range LINEAR sRGB values.

    A hard per-channel clip at the cube edge visibly distorts hue (a too-bright
    warm highlight clips to yellow; deep saturated blues clip cyan-ward). Instead,
    out-of-gamut colours keep their Oklab hue and lightness while their CHROMA is
    bisected down to the gamut surface — Ottosson's constant-hue projection, the
    recipe CSS Color 4 standardised. In-gamut values pass through untouched."""
    from .colorspace import linear_to_oklab, oklab_to_linear
    lin = np.asarray(lin, dtype=np.float64)
    flat = lin.reshape(-1, 3)
    eps = 1e-6
    oog = np.any((flat < -eps) | (flat > 1.0 + eps), axis=-1)
    if not oog.any():
        return np.clip(lin, 0.0, 1.0)
    bad = flat[oog]
    lab = linear_to_oklab(np.clip(bad, 0.0, None))
    L = np.clip(lab[:, :1], 0.0, 1.0)
    ab = lab[:, 1:]
    lo = np.zeros((bad.shape[0], 1))
    hi = np.ones((bad.shape[0], 1))
    for _ in range(9):                    # bisect the largest in-gamut chroma
        mid = (lo + hi) / 2.0
        cand = oklab_to_linear(np.concatenate([L, ab * mid], axis=1))
        inside = np.all((cand > -1e-4) & (cand < 1.0 + 1e-4), axis=1, keepdims=True)
        lo = np.where(inside, mid, lo)
        hi = np.where(inside, hi, mid)
    mapped = oklab_to_linear(np.concatenate([L, ab * lo], axis=1))
    out = np.clip(flat, 0.0, 1.0)
    out[oog] = np.clip(mapped, 0.0, 1.0)
    return out.reshape(lin.shape)


def build_lut(transform_lin, size: int = 65, tf: str = "sRGB") -> np.ndarray:
    """Sample `transform_lin` on an encoded grid -> LUT array indexed [r, g, b, 3]."""
    axis = np.linspace(0.0, 1.0, size)
    R, G, B = np.meshgrid(axis, axis, axis, indexing="ij")  # [r,g,b]
    enc_in = np.stack([R, G, B], axis=-1).reshape(-1, 3)
    lin_in = decode(enc_in, tf)
    lin_out = soft_gamut(transform_lin(lin_in))   # hue-preserving, not a hard clip
    enc_out = np.clip(encode(lin_out, tf), 0.0, 1.0)
    return enc_out.reshape(size, size, size, 3)


def write_cube(path: str | Path, lut: np.ndarray, title: str = "colourMatik") -> None:
    """Write an Adobe .cube 3D LUT. RED varies fastest (Adobe/Resolve spec)."""
    size = lut.shape[0]
    out = [
        f'TITLE "{title}"',
        f"LUT_3D_SIZE {size}",
        "DOMAIN_MIN 0.0 0.0 0.0",
        "DOMAIN_MAX 1.0 1.0 1.0",
        "",
    ]
    # red fastest, then green, then blue -> b outer, g middle, r inner
    flat = np.empty((size * size * size, 3), dtype=np.float64)
    i = 0
    for b in range(size):
        for g in range(size):
            for r in range(size):
                flat[i] = lut[r, g, b]
                i += 1
    for px in flat:
        out.append(f"{px[0]:.6f} {px[1]:.6f} {px[2]:.6f}")
    # atomic write: temp file + replace, so a concurrent reader never sees a partial LUT
    path = Path(path)
    tmp = path.with_name(path.name + f".tmp{os.getpid()}")
    tmp.write_text("\n".join(out) + "\n")
    os.replace(tmp, path)


def _interp(lut: np.ndarray) -> RegularGridInterpolator:
    size = lut.shape[0]
    axis = np.linspace(0.0, 1.0, size)
    return RegularGridInterpolator(
        (axis, axis, axis), lut, method="linear", bounds_error=False, fill_value=None
    )


def apply_intensity(lut: np.ndarray, intensity: float) -> np.ndarray:
    """Blend a LUT toward identity: identity + t*(lut - identity).

    t=0 -> no change, t=1 -> full match, t>1 -> stronger (extrapolated). Lets the
    same match be dialed up or down without re-fitting."""
    t = float(intensity)
    if not np.isfinite(t):        # a NaN/Inf intensity must not poison the whole LUT
        t = 1.0
    if t == 1.0:
        return lut
    size = lut.shape[0]
    axis = np.linspace(0.0, 1.0, size)
    R, G, B = np.meshgrid(axis, axis, axis, indexing="ij")
    identity = np.stack([R, G, B], axis=-1)
    return np.clip(identity + t * (lut - identity), 0.0, 1.0)


def apply_lut(img_enc: np.ndarray, lut: np.ndarray) -> np.ndarray:
    """Apply a 3D LUT to a display-encoded image via trilinear interpolation."""
    shape = img_enc.shape
    pts = np.clip(img_enc.reshape(-1, 3), 0.0, 1.0)
    return np.clip(_interp(lut)(pts).reshape(shape), 0.0, 1.0)


def apply_lut_points(lut: np.ndarray, pts_enc: np.ndarray) -> np.ndarray:
    """Apply a 3D LUT to an (N,3) array of display-encoded points."""
    pts = np.clip(pts_enc, 0.0, 1.0)
    return np.clip(_interp(lut)(pts), 0.0, 1.0)


def resample_lut(lut: np.ndarray, new_size: int) -> np.ndarray:
    """Resample a LUT lattice onto a finer/coarser cube via trilinear interpolation."""
    if lut.shape[0] == new_size:
        return lut
    axis = np.linspace(0.0, 1.0, new_size)
    R, G, B = np.meshgrid(axis, axis, axis, indexing="ij")
    pts = np.stack([R, G, B], axis=-1).reshape(-1, 3)
    out = _interp(lut)(pts).reshape(new_size, new_size, new_size, 3)
    return np.clip(out, 0.0, 1.0)
