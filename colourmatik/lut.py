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


def build_lut(transform_lin, size: int = 65, tf: str = "sRGB") -> np.ndarray:
    """Sample `transform_lin` on an encoded grid -> LUT array indexed [r, g, b, 3]."""
    axis = np.linspace(0.0, 1.0, size)
    R, G, B = np.meshgrid(axis, axis, axis, indexing="ij")  # [r,g,b]
    enc_in = np.stack([R, G, B], axis=-1).reshape(-1, 3)
    lin_in = decode(enc_in, tf)
    lin_out = np.clip(transform_lin(lin_in), 0.0, None)
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
